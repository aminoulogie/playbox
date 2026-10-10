#include "LibtorrentNative.h"

#include <CoreFoundation/CoreFoundation.h>

#include <libtorrent/add_torrent_params.hpp>
#include <libtorrent/alert_types.hpp>
#include <libtorrent/announce_entry.hpp>
#include <libtorrent/bdecode.hpp>
#include <libtorrent/download_priority.hpp>
#include <libtorrent/error_code.hpp>
#include <libtorrent/file_storage.hpp>
#include <libtorrent/hex.hpp>
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/session.hpp>
#include <libtorrent/session_status.hpp>
#include <libtorrent/settings_pack.hpp>
#include <libtorrent/torrent_handle.hpp>
#include <libtorrent/torrent_info.hpp>
#include <libtorrent/torrent_status.hpp>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cctype>
#include <cstdlib>
#include <cstdint>
#include <cstdio>
#include <iomanip>
#include <limits>
#include <memory>
#include <mutex>
#include <optional>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <unordered_map>
#include <utility>
#include <vector>

namespace {
namespace lt = libtorrent;

bool configure_openssl_ca_bundle() {
    CFBundleRef bundle = CFBundleGetBundleWithIdentifier(CFSTR("io.github.tryagi.libtorrent-native"));
    if (bundle == nullptr) {
        return false;
    }

    CFURLRef url = CFBundleCopyResourceURL(bundle, CFSTR("cacert"), CFSTR("pem"), nullptr);
    if (url == nullptr) {
        return false;
    }

    std::vector<UInt8> path(4096);
    const Boolean resolved = CFURLGetFileSystemRepresentation(
        url,
        true,
        path.data(),
        static_cast<CFIndex>(path.size())
    );
    CFRelease(url);
    if (!resolved) {
        return false;
    }

    return setenv("SSL_CERT_FILE", reinterpret_cast<const char *>(path.data()), 1) == 0;
}

struct FileSelection {
    bool all = false;
    std::vector<int> file_indexes;
    std::vector<std::string> globs;
    std::optional<int> primary_file_index;
    std::vector<int> priority_file_indexes;
};

struct StartRequest {
    std::string job_id;
    std::string magnet_uri;
    std::string torrent_data_base64;
    std::string download_directory;
    std::optional<long long> download_rate_limit;
    std::optional<long long> upload_rate_limit;
    std::optional<FileSelection> selection;
};

struct JobState {
    std::string job_id;
    lt::torrent_handle handle;
    std::optional<FileSelection> pending_selection;
    bool completed_sent = false;
    struct SwarmEvents {
        struct Tracker {
            std::string last_event;
            std::optional<std::chrono::steady_clock::time_point> last_event_at;
            std::optional<int> last_response_peer_count;
            std::optional<int> last_error_code;
            std::optional<int> last_http_status_code;
        };

        std::unordered_map<std::string, Tracker> trackers;
        std::optional<std::chrono::steady_clock::time_point> last_dht_reply_at;
        std::optional<int> last_dht_reply_peer_count;
    } swarm_events;
};

struct PortMappingEvent {
    std::string transport;
    std::string protocol_name;
    std::string status;
    std::optional<int> last_error_code;
    std::optional<std::chrono::steady_clock::time_point> last_event_at;
};

struct DhtSessionEvents {
    std::optional<std::chrono::steady_clock::time_point> last_bootstrap_at;
    std::optional<std::chrono::steady_clock::time_point> last_error_at;
    std::optional<int> last_error_code;
};

std::string json_escape(const std::string &value) {
    std::ostringstream output;
    for (const unsigned char character : value) {
        switch (character) {
        case '"':
            output << "\\\"";
            break;
        case '\\':
            output << "\\\\";
            break;
        case '\b':
            output << "\\b";
            break;
        case '\f':
            output << "\\f";
            break;
        case '\n':
            output << "\\n";
            break;
        case '\r':
            output << "\\r";
            break;
        case '\t':
            output << "\\t";
            break;
        default:
            if (character < 0x20) {
                output << "\\u" << std::hex << std::setw(4) << std::setfill('0') << int(character);
            } else {
                output << character;
            }
            break;
        }
    }
    return output.str();
}

std::optional<std::string> extract_json_string(const std::string &json, const std::string &key) {
    const std::string needle = "\"" + key + "\"";
    const auto key_position = json.find(needle);
    if (key_position == std::string::npos) {
        return std::nullopt;
    }

    auto cursor = json.find(':', key_position + needle.size());
    if (cursor == std::string::npos) {
        return std::nullopt;
    }

    ++cursor;
    while (cursor < json.size() && std::isspace(static_cast<unsigned char>(json[cursor]))) {
        ++cursor;
    }

    if (cursor >= json.size() || json[cursor] != '"') {
        return std::nullopt;
    }

    ++cursor;
    std::string value;
    while (cursor < json.size()) {
        const char character = json[cursor++];
        if (character == '"') {
            return value;
        }
        if (character == '\\' && cursor < json.size()) {
            const char escaped = json[cursor++];
            switch (escaped) {
            case '"':
            case '\\':
            case '/':
                value.push_back(escaped);
                break;
            case 'b':
                value.push_back('\b');
                break;
            case 'f':
                value.push_back('\f');
                break;
            case 'n':
                value.push_back('\n');
                break;
            case 'r':
                value.push_back('\r');
                break;
            case 't':
                value.push_back('\t');
                break;
            default:
                value.push_back(escaped);
                break;
            }
        } else {
            value.push_back(character);
        }
    }

    return std::nullopt;
}

std::optional<long long> extract_json_int(const std::string &json, const std::string &key) {
    const std::string needle = "\"" + key + "\"";
    const auto key_position = json.find(needle);
    if (key_position == std::string::npos) {
        return std::nullopt;
    }

    auto cursor = json.find(':', key_position + needle.size());
    if (cursor == std::string::npos) {
        return std::nullopt;
    }

    ++cursor;
    while (cursor < json.size() && std::isspace(static_cast<unsigned char>(json[cursor]))) {
        ++cursor;
    }

    const auto start = cursor;
    if (cursor < json.size() && json[cursor] == '-') {
        ++cursor;
    }
    while (cursor < json.size() && std::isdigit(static_cast<unsigned char>(json[cursor]))) {
        ++cursor;
    }

    if (cursor == start || (cursor == start + 1 && json[start] == '-')) {
        return std::nullopt;
    }

    try {
        return std::stoll(json.substr(start, cursor - start));
    } catch (...) {
        return std::nullopt;
    }
}

std::optional<bool> extract_json_bool(const std::string &json, const std::string &key) {
    const std::string needle = "\"" + key + "\"";
    const auto key_position = json.find(needle);
    if (key_position == std::string::npos) {
        return std::nullopt;
    }

    auto cursor = json.find(':', key_position + needle.size());
    if (cursor == std::string::npos) {
        return std::nullopt;
    }

    ++cursor;
    while (cursor < json.size() && std::isspace(static_cast<unsigned char>(json[cursor]))) {
        ++cursor;
    }

    if (json.compare(cursor, 4, "true") == 0) {
        return true;
    }
    if (json.compare(cursor, 5, "false") == 0) {
        return false;
    }
    return std::nullopt;
}

std::optional<std::string> extract_json_array_body(const std::string &json, const std::string &key) {
    const std::string needle = "\"" + key + "\"";
    const auto key_position = json.find(needle);
    if (key_position == std::string::npos) {
        return std::nullopt;
    }

    auto cursor = json.find(':', key_position + needle.size());
    if (cursor == std::string::npos) {
        return std::nullopt;
    }

    cursor = json.find('[', cursor);
    if (cursor == std::string::npos) {
        return std::nullopt;
    }

    const auto start = cursor + 1;
    int depth = 1;
    bool in_string = false;
    bool escaping = false;
    ++cursor;
    while (cursor < json.size()) {
        const char character = json[cursor];
        if (escaping) {
            escaping = false;
        } else if (character == '\\' && in_string) {
            escaping = true;
        } else if (character == '"') {
            in_string = !in_string;
        } else if (!in_string && character == '[') {
            ++depth;
        } else if (!in_string && character == ']') {
            --depth;
            if (depth == 0) {
                return json.substr(start, cursor - start);
            }
        }
        ++cursor;
    }

    return std::nullopt;
}

std::vector<int> extract_json_int_array(const std::string &json, const std::string &key) {
    const auto body = extract_json_array_body(json, key);
    if (!body.has_value()) {
        return {};
    }

    std::vector<int> values;
    std::size_t cursor = 0;
    while (cursor < body->size()) {
        while (cursor < body->size() && !std::isdigit(static_cast<unsigned char>((*body)[cursor])) && (*body)[cursor] != '-') {
            ++cursor;
        }
        if (cursor >= body->size()) {
            break;
        }

        const auto start = cursor;
        if ((*body)[cursor] == '-') {
            ++cursor;
        }
        while (cursor < body->size() && std::isdigit(static_cast<unsigned char>((*body)[cursor]))) {
            ++cursor;
        }

        try {
            const auto value = std::stoll(body->substr(start, cursor - start));
            if (value >= 0 && value <= std::numeric_limits<int>::max()) {
                values.push_back(static_cast<int>(value));
            }
        } catch (...) {
        }
    }

    return values;
}

std::vector<std::string> extract_json_string_array(const std::string &json, const std::string &key) {
    const auto body = extract_json_array_body(json, key);
    if (!body.has_value()) {
        return {};
    }

    std::vector<std::string> values;
    std::size_t cursor = 0;
    while (cursor < body->size()) {
        while (cursor < body->size() && (*body)[cursor] != '"') {
            ++cursor;
        }
        if (cursor >= body->size()) {
            break;
        }

        ++cursor;
        std::string value;
        while (cursor < body->size()) {
            const char character = (*body)[cursor++];
            if (character == '"') {
                values.push_back(value);
                break;
            }
            if (character == '\\' && cursor < body->size()) {
                const char escaped = (*body)[cursor++];
                switch (escaped) {
                case '"':
                case '\\':
                case '/':
                    value.push_back(escaped);
                    break;
                case 'b':
                    value.push_back('\b');
                    break;
                case 'f':
                    value.push_back('\f');
                    break;
                case 'n':
                    value.push_back('\n');
                    break;
                case 'r':
                    value.push_back('\r');
                    break;
                case 't':
                    value.push_back('\t');
                    break;
                default:
                    value.push_back(escaped);
                    break;
                }
            } else {
                value.push_back(character);
            }
        }
    }

    return values;
}

std::string lowercase_ascii(std::string value) {
    std::transform(value.begin(), value.end(), value.begin(), [](unsigned char character) {
        return static_cast<char>(std::tolower(character));
    });
    return value;
}

/// Returns only the tracker origin so private paths, passkeys, credentials,
/// and query parameters never cross the native ABI boundary.
std::string redact_tracker_endpoint(const std::string &value) {
    const auto scheme_end = value.find("://");
    if (scheme_end == std::string::npos || scheme_end == 0) {
        return {};
    }

    const auto authority_start = scheme_end + 3;
    const auto authority_end = value.find_first_of("/?#", authority_start);
    std::string authority = value.substr(
        authority_start,
        authority_end == std::string::npos ? std::string::npos : authority_end - authority_start
    );
    const auto user_info_end = authority.rfind('@');
    if (user_info_end != std::string::npos) {
        authority.erase(0, user_info_end + 1);
    }
    if (authority.empty()) {
        return {};
    }

    return lowercase_ascii(value.substr(0, scheme_end)) + "://" + lowercase_ascii(authority);
}

void emit_optional_int_json(std::ostringstream &json, const std::optional<int> &value) {
    if (value.has_value()) {
        json << *value;
    } else {
        json << "null";
    }
}

void emit_optional_bool_json(std::ostringstream &json, const std::optional<bool> &value) {
    if (value.has_value()) {
        json << (*value ? "true" : "false");
    } else {
        json << "null";
    }
}

void emit_optional_string_json(std::ostringstream &json, const std::optional<std::string> &value) {
    if (value.has_value()) {
        json << "\"" << json_escape(*value) << "\"";
    } else {
        json << "null";
    }
}

std::optional<int> non_negative_optional(int value) {
    return value >= 0 ? std::optional<int>(value) : std::nullopt;
}

std::optional<int> age_in_seconds(const std::optional<std::chrono::steady_clock::time_point> &time) {
    if (!time.has_value()) {
        return std::nullopt;
    }

    const auto elapsed = std::chrono::steady_clock::now() - *time;
    return static_cast<int>(std::max<std::int64_t>(
        0,
        std::chrono::duration_cast<std::chrono::seconds>(elapsed).count()
    ));
}

const char *portmap_transport_name(lt::portmap_transport transport) {
    switch (transport) {
    case lt::portmap_transport::natpmp:
        return "nat_pmp";
    case lt::portmap_transport::upnp:
        return "upnp";
    }
    return "unknown";
}

const char *portmap_protocol_name(lt::portmap_protocol protocol) {
    switch (protocol) {
    case lt::portmap_protocol::tcp:
        return "tcp";
    case lt::portmap_protocol::udp:
        return "udp";
    case lt::portmap_protocol::none:
        return "none";
    }
    return "unknown";
}

bool wildcard_match(std::string pattern, std::string value) {
    pattern = lowercase_ascii(std::move(pattern));
    value = lowercase_ascii(std::move(value));

    std::size_t pattern_index = 0;
    std::size_t value_index = 0;
    std::size_t star_index = std::string::npos;
    std::size_t match_index = 0;

    while (value_index < value.size()) {
        if (pattern_index < pattern.size() &&
            (pattern[pattern_index] == '?' || pattern[pattern_index] == value[value_index])) {
            ++pattern_index;
            ++value_index;
        } else if (pattern_index < pattern.size() && pattern[pattern_index] == '*') {
            star_index = pattern_index++;
            match_index = value_index;
        } else if (star_index != std::string::npos) {
            pattern_index = star_index + 1;
            value_index = ++match_index;
        } else {
            return false;
        }
    }

    while (pattern_index < pattern.size() && pattern[pattern_index] == '*') {
        ++pattern_index;
    }

    return pattern_index == pattern.size();
}

std::string percent_decode(std::string value) {
    std::string decoded;
    decoded.reserve(value.size());

    for (std::size_t index = 0; index < value.size(); ++index) {
        if (value[index] == '%' && index + 2 < value.size()) {
            const std::string hex = value.substr(index + 1, 2);
            char *end = nullptr;
            const long code = std::strtol(hex.c_str(), &end, 16);
            if (end != nullptr && *end == '\0') {
                decoded.push_back(static_cast<char>(code));
                index += 2;
                continue;
            }
        }
        decoded.push_back(value[index]);
    }

    return decoded;
}

std::string file_url_to_path(std::string value) {
    constexpr const char *prefix = "file://";
    if (value.rfind(prefix, 0) != 0) {
        return value;
    }

    value.erase(0, std::char_traits<char>::length(prefix));
    if (value.rfind("localhost/", 0) == 0) {
        value.erase(0, std::char_traits<char>::length("localhost"));
    }
    if (!value.empty() && value.front() != '/') {
        value.insert(value.begin(), '/');
    }

    return percent_decode(value);
}

std::vector<std::uint8_t> base64_decode(const std::string &value) {
    static constexpr unsigned char invalid = 255;
    static unsigned char table[256] = {};
    static std::once_flag table_once;
    std::call_once(table_once, [] {
        for (auto &entry : table) {
            entry = invalid;
        }
        const std::string alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        for (std::size_t index = 0; index < alphabet.size(); ++index) {
            table[static_cast<unsigned char>(alphabet[index])] = static_cast<unsigned char>(index);
        }
    });

    std::vector<std::uint8_t> output;
    int accumulator = 0;
    int bits = -8;
    for (const unsigned char character : value) {
        if (std::isspace(character)) {
            continue;
        }
        if (character == '=') {
            break;
        }
        if (table[character] == invalid) {
            continue;
        }
        accumulator = (accumulator << 6) + table[character];
        bits += 6;
        if (bits >= 0) {
            output.push_back(static_cast<std::uint8_t>((accumulator >> bits) & 0xff));
            bits -= 8;
        }
    }
    return output;
}

std::optional<FileSelection> parse_file_selection(const std::string &json) {
    FileSelection selection;
    selection.all = extract_json_bool(json, "all").value_or(false);
    selection.file_indexes = extract_json_int_array(json, "fileIndexes");
    selection.globs = extract_json_string_array(json, "globs");
    selection.priority_file_indexes = extract_json_int_array(json, "priorityFileIndexes");
    if (const auto primary_file_index = extract_json_int(json, "primaryFileIndex");
        primary_file_index.has_value() &&
        *primary_file_index >= 0 &&
        *primary_file_index <= std::numeric_limits<int>::max()) {
        selection.primary_file_index = static_cast<int>(*primary_file_index);
    }

    if (!selection.all &&
        selection.file_indexes.empty() &&
        selection.globs.empty() &&
        selection.priority_file_indexes.empty() &&
        !selection.primary_file_index.has_value()) {
        return std::nullopt;
    }

    return selection;
}

StartRequest parse_start_request(const char *json) {
    const std::string request_json = json == nullptr ? "" : json;
    StartRequest request;
    request.job_id = extract_json_string(request_json, "jobId").value_or("");
    request.magnet_uri = extract_json_string(request_json, "magnetUri").value_or("");
    request.torrent_data_base64 = extract_json_string(request_json, "torrentData").value_or("");
    request.download_directory = file_url_to_path(
        extract_json_string(request_json, "downloadDirectory").value_or("")
    );
    request.download_rate_limit = extract_json_int(request_json, "downloadBytesPerSecond");
    request.upload_rate_limit = extract_json_int(request_json, "uploadBytesPerSecond");
    request.selection = parse_file_selection(request_json);
    return request;
}

std::string parse_job_id(const char *json) {
    const std::string request_json = json == nullptr ? "" : json;
    return extract_json_string(request_json, "jobId").value_or("");
}

lt::settings_pack make_settings() {
    if (!configure_openssl_ca_bundle()) {
        throw std::runtime_error("Unable to configure the bundled TLS certificate store");
    }
    lt::settings_pack settings;
    settings.set_int(
        lt::settings_pack::alert_mask,
        lt::alert_category::error
            | lt::alert_category::storage
            | lt::alert_category::status
            | lt::alert_category::tracker
            | lt::alert_category::dht
            | lt::alert_category::port_mapping
    );
    settings.set_bool(lt::settings_pack::enable_dht, true);
    settings.set_bool(lt::settings_pack::enable_lsd, true);
    settings.set_bool(lt::settings_pack::enable_upnp, true);
    settings.set_bool(lt::settings_pack::enable_natpmp, true);
    settings.set_bool(lt::settings_pack::prioritize_partial_pieces, true);
    settings.set_bool(lt::settings_pack::piece_extent_affinity, true);
    settings.set_int(lt::settings_pack::max_web_seed_connections, 12);
    settings.set_int(lt::settings_pack::urlseed_pipeline_size, 10);
    return settings;
}

int clamp_rate_limit(long long value) {
    if (value <= 0) {
        return 0;
    }
    if (value > std::numeric_limits<int>::max()) {
        return std::numeric_limits<int>::max();
    }
    return static_cast<int>(value);
}

void apply_rate_limits(lt::torrent_handle &handle, const StartRequest &request) {
    if (request.download_rate_limit.has_value()) {
        handle.set_download_limit(clamp_rate_limit(*request.download_rate_limit));
    }
    if (request.upload_rate_limit.has_value()) {
        handle.set_upload_limit(clamp_rate_limit(*request.upload_rate_limit));
    }
}

void apply_rate_limits(lt::torrent_handle &handle, long long download_rate_limit, long long upload_rate_limit) {
    handle.set_download_limit(clamp_rate_limit(download_rate_limit));
    handle.set_upload_limit(clamp_rate_limit(upload_rate_limit));
}

bool is_file_selected_by_glob(const std::vector<std::string> &globs, const std::string &path) {
    if (globs.empty()) {
        return false;
    }

    const auto slash_position = path.find_last_of("/\\");
    const auto file_name = slash_position == std::string::npos
        ? path
        : path.substr(slash_position + 1);

    return std::any_of(globs.begin(), globs.end(), [&](const std::string &glob) {
        return wildcard_match(glob, path) || wildcard_match(glob, file_name);
    });
}

bool apply_file_selection(lt::torrent_handle &handle, const FileSelection &selection) {
    const auto torrent_info = handle.torrent_file();
    if (!torrent_info) {
        return false;
    }

    const auto &files = torrent_info->files();
    const auto file_count = files.num_files();
    if (file_count <= 0) {
        return false;
    }

    std::vector<lt::download_priority_t> priorities(
        static_cast<std::size_t>(file_count),
        selection.all ? lt::default_priority : lt::dont_download
    );

    for (const auto file_index : selection.file_indexes) {
        if (file_index >= 0 && file_index < file_count) {
            priorities[static_cast<std::size_t>(file_index)] = lt::default_priority;
        }
    }

    for (std::size_t rank = 0; rank < selection.priority_file_indexes.size(); ++rank) {
        const auto file_index = selection.priority_file_indexes[rank];
        if (file_index >= 0 && file_index < file_count) {
            const auto value = static_cast<std::uint8_t>(std::max(1, 7 - static_cast<int>(rank)));
            priorities[static_cast<std::size_t>(file_index)] = lt::download_priority_t{value};
        }
    }

    for (int index = 0; index < file_count; ++index) {
        const lt::file_index_t file_index{index};
        if (is_file_selected_by_glob(selection.globs, files.file_path(file_index))) {
            priorities[static_cast<std::size_t>(index)] = lt::default_priority;
        }
    }

    if (selection.primary_file_index.has_value() &&
        *selection.primary_file_index >= 0 &&
        *selection.primary_file_index < file_count) {
        priorities[static_cast<std::size_t>(*selection.primary_file_index)] = lt::top_priority;
    }

    handle.prioritize_files(priorities);
    return true;
}

bool apply_pending_selection(lt::torrent_handle &handle, JobState &state) {
    if (!state.pending_selection.has_value()) {
        return true;
    }

    if (!apply_file_selection(handle, *state.pending_selection)) {
        return false;
    }

    state.pending_selection.reset();
    return true;
}

void emit_info_hash_json(std::ostringstream &json, const lt::torrent_handle &handle) {
    const auto hashes = handle.info_hashes();
    if (!hashes.has_v1() && !hashes.has_v2()) {
        json << "null";
        return;
    }

    const auto bytes = hashes.get_best().to_string();
    json << "\"" << json_escape(lt::aux::to_hex(bytes)) << "\"";
}

void emit_files_json(std::ostringstream &json, const lt::torrent_handle &handle) {
    const auto torrent_info = handle.torrent_file();
    if (!torrent_info) {
        json << "[]";
        return;
    }

    const auto &files = torrent_info->files();
    std::vector<std::int64_t> progress;
    handle.file_progress(progress, lt::torrent_handle::piece_granularity);
    const auto priorities = handle.get_file_priorities();

    json << "[";
    for (int index = 0; index < files.num_files(); ++index) {
        if (index > 0) {
            json << ",";
        }

        const lt::file_index_t file_index{index};
        const std::int64_t size = files.file_size(file_index);
        const std::int64_t completed = index < static_cast<int>(progress.size()) ? progress[index] : 0;
        const bool is_selected = index >= static_cast<int>(priorities.size())
            ? true
            : static_cast<int>(priorities[static_cast<std::size_t>(index)]) > 0;
        const double percent = size > 0
            ? std::clamp((static_cast<double>(completed) / static_cast<double>(size)) * 100.0, 0.0, 100.0)
            : 0.0;

        json << "{";
        json << "\"id\":" << index << ",";
        json << "\"path\":\"" << json_escape(files.file_path(file_index)) << "\",";
        json << "\"sizeBytes\":" << size << ",";
        json << "\"isSelected\":" << (is_selected ? "true" : "false") << ",";
        json << "\"bytesCompleted\":" << completed << ",";
        json << "\"percentComplete\":" << percent;
        json << "}";
    }
    json << "]";
}

class NativeSession {
public:
    NativeSession(tryagi_libtorrent_event_callback_t callback, void *context)
        : callback_(callback),
          context_(context),
          session_(make_settings()),
          worker_([this] { pump_progress(); }) {}

    ~NativeSession() {
        stopping_.store(true);
        if (worker_.joinable()) {
            worker_.join();
        }
    }

    int start(const char *json) {
        try {
            auto request = parse_start_request(json);
            if (request.job_id.empty()) {
                return fail("start request is missing jobId");
            }
            if (request.download_directory.empty()) {
                return fail("start request is missing downloadDirectory");
            }

            lt::add_torrent_params params;
            if (!request.magnet_uri.empty()) {
                lt::error_code error;
                params = lt::parse_magnet_uri(request.magnet_uri, error);
                if (error) {
                    return fail("failed to parse magnet URI: " + error.message());
                }
            } else if (!request.torrent_data_base64.empty()) {
                const auto torrent_data = base64_decode(request.torrent_data_base64);
                lt::error_code error;
                lt::bdecode_node decoded;
                lt::bdecode(
                    reinterpret_cast<const char *>(torrent_data.data()),
                    reinterpret_cast<const char *>(torrent_data.data() + torrent_data.size()),
                    decoded,
                    error
                );
                if (error) {
                    return fail("failed to decode torrent data: " + error.message());
                }
                params.ti = std::make_shared<lt::torrent_info>(decoded, error);
                if (error) {
                    return fail("failed to load torrent metadata: " + error.message());
                }
            } else {
                return fail("start request is missing magnetUri or torrentData");
            }

            params.save_path = request.download_directory;
            const bool awaiting_selection = !request.selection.has_value()
                && params.ti
                && params.ti->num_files() > 1;
            if (awaiting_selection) {
                params.file_priorities.assign(
                    static_cast<std::size_t>(params.ti->num_files()),
                    lt::dont_download
                );
            }
            lt::error_code error;
            auto handle = session_.add_torrent(std::move(params), error);
            if (error) {
                return fail("failed to add torrent: " + error.message());
            }
            apply_rate_limits(handle, request);
            auto pending_selection = request.selection;
            if (pending_selection.has_value() && apply_file_selection(handle, *pending_selection)) {
                pending_selection.reset();
            }

            {
                std::lock_guard<std::mutex> guard(lock_);
                jobs_[request.job_id] = JobState{request.job_id, handle, pending_selection, false};
            }
            emit_progress(request.job_id, handle, false);
            return 0;
        } catch (const std::exception &error) {
            return fail(error.what());
        }
    }

    int apply_selection(const char *json) {
        const auto job_id = parse_job_id(json);
        if (job_id.empty()) {
            return fail("selection request is missing jobId");
        }
        const auto selection = parse_file_selection(json);
        if (!selection.has_value()) {
            return fail("selection request is missing all, fileIndexes, globs, or primaryFileIndex");
        }

        std::lock_guard<std::mutex> guard(lock_);
        auto iterator = jobs_.find(job_id);
        if (iterator == jobs_.end()) {
            return fail("selection request references an unknown jobId");
        }
        iterator->second.pending_selection = selection;
        apply_pending_selection(iterator->second.handle, iterator->second);
        return 0;
    }

    int update_rate_limits(const char *json) {
        const std::string request_json = json == nullptr ? "" : json;
        const auto download_rate_limit = extract_json_int(request_json, "downloadBytesPerSecond").value_or(0);
        const auto upload_rate_limit = extract_json_int(request_json, "uploadBytesPerSecond").value_or(0);
        return with_handle(json, [&](lt::torrent_handle &handle) {
            apply_rate_limits(handle, download_rate_limit, upload_rate_limit);
        });
    }

    int reannounce(const char *json) {
        return with_handle(json, [](lt::torrent_handle &handle) {
            handle.force_reannounce();
        });
    }

    int refresh_peers(const char *json) {
        return with_handle(json, [](lt::torrent_handle &handle) {
            handle.force_reannounce();
            handle.force_dht_announce();
        });
    }

    int pause(const char *json) {
        return with_handle(json, [](lt::torrent_handle &handle) {
            handle.pause();
        });
    }

    int resume(const char *json) {
        return with_handle(json, [](lt::torrent_handle &handle) {
            handle.resume();
        });
    }

    int cancel(const char *json) {
        const auto job_id = parse_job_id(json);
        if (job_id.empty()) {
            return fail("cancel request is missing jobId");
        }

        lt::torrent_handle handle;
        {
            std::lock_guard<std::mutex> guard(lock_);
            auto iterator = jobs_.find(job_id);
            if (iterator == jobs_.end()) {
                return fail("cancel request references an unknown jobId");
            }
            handle = iterator->second.handle;
            jobs_.erase(iterator);
        }

        if (handle.is_valid()) {
            session_.remove_torrent(handle);
        }
        return 0;
    }

    const char *last_error() const {
        std::lock_guard<std::mutex> guard(lock_);
        return last_error_.empty() ? nullptr : last_error_.c_str();
    }

private:
    template <typename Operation>
    int with_handle(const char *json, Operation operation) {
        const auto job_id = parse_job_id(json);
        if (job_id.empty()) {
            return fail("control request is missing jobId");
        }

        lt::torrent_handle handle;
        {
            std::lock_guard<std::mutex> guard(lock_);
            auto iterator = jobs_.find(job_id);
            if (iterator == jobs_.end()) {
                return fail("control request references an unknown jobId");
            }
            handle = iterator->second.handle;
        }

        if (!handle.is_valid()) {
            return fail("torrent handle is invalid");
        }

        operation(handle);
        return 0;
    }

    int fail(std::string message) {
        std::lock_guard<std::mutex> guard(lock_);
        last_error_ = std::move(message);
        return -1;
    }

    JobState::SwarmEvents swarm_events_for(const std::string &job_id) const {
        std::lock_guard<std::mutex> guard(lock_);
        const auto iterator = jobs_.find(job_id);
        return iterator == jobs_.end() ? JobState::SwarmEvents{} : iterator->second.swarm_events;
    }

    DhtSessionEvents dht_events() const {
        std::lock_guard<std::mutex> guard(lock_);
        return dht_events_;
    }

    std::unordered_map<int, PortMappingEvent> port_mapping_events() const {
        std::lock_guard<std::mutex> guard(lock_);
        return port_mapping_events_;
    }

    void record_tracker_event(
        const lt::tracker_alert &alert,
        std::string event,
        std::optional<int> response_peer_count = std::nullopt,
        std::optional<int> error_code = std::nullopt,
        std::optional<int> http_status_code = std::nullopt
    ) {
        const std::string endpoint = redact_tracker_endpoint(alert.tracker_url());
        if (endpoint.empty()) {
            return;
        }

        const auto now = std::chrono::steady_clock::now();
        std::lock_guard<std::mutex> guard(lock_);
        for (auto &entry : jobs_) {
            if (entry.second.handle != alert.handle) {
                continue;
            }

            auto &tracker = entry.second.swarm_events.trackers[endpoint];
            tracker.last_event = std::move(event);
            tracker.last_event_at = now;
            if (response_peer_count.has_value()) {
                tracker.last_response_peer_count = response_peer_count;
            }
            if (error_code.has_value()) {
                tracker.last_error_code = error_code;
            } else if (tracker.last_event == "reply") {
                tracker.last_error_code.reset();
            }
            tracker.last_http_status_code = http_status_code;
            return;
        }
    }

    void record_dht_reply(const lt::dht_reply_alert &alert) {
        const auto now = std::chrono::steady_clock::now();
        std::lock_guard<std::mutex> guard(lock_);
        for (auto &entry : jobs_) {
            if (entry.second.handle == alert.handle) {
                entry.second.swarm_events.last_dht_reply_at = now;
                entry.second.swarm_events.last_dht_reply_peer_count = alert.num_peers;
                dht_events_.last_error_at.reset();
                dht_events_.last_error_code.reset();
                return;
            }
        }
    }

    void record_dht_bootstrap() {
        std::lock_guard<std::mutex> guard(lock_);
        dht_events_.last_bootstrap_at = std::chrono::steady_clock::now();
        dht_events_.last_error_at.reset();
        dht_events_.last_error_code.reset();
    }

    void record_dht_error(int error_code) {
        std::lock_guard<std::mutex> guard(lock_);
        dht_events_.last_error_at = std::chrono::steady_clock::now();
        dht_events_.last_error_code = error_code;
    }

    void record_port_mapping_success(const lt::portmap_alert &alert) {
        const int mapping_index = static_cast<int>(alert.mapping);
        std::lock_guard<std::mutex> guard(lock_);
        port_mapping_events_[mapping_index] = PortMappingEvent{
            portmap_transport_name(alert.map_transport),
            portmap_protocol_name(alert.map_protocol),
            "mapped",
            std::nullopt,
            std::chrono::steady_clock::now(),
        };
    }

    void record_port_mapping_error(const lt::portmap_error_alert &alert) {
        const int mapping_index = static_cast<int>(alert.mapping);
        std::lock_guard<std::mutex> guard(lock_);
        port_mapping_events_[mapping_index] = PortMappingEvent{
            portmap_transport_name(alert.map_transport),
            "unknown",
            "error",
            alert.error.value(),
            std::chrono::steady_clock::now(),
        };
    }

    void process_alerts() {
        std::vector<lt::alert *> alerts;
        session_.pop_alerts(&alerts);

        for (const auto *alert : alerts) {
            if (const auto *tracker = lt::alert_cast<lt::tracker_announce_alert>(alert)) {
                record_tracker_event(*tracker, "announce");
            } else if (const auto *tracker = lt::alert_cast<lt::tracker_reply_alert>(alert)) {
                record_tracker_event(*tracker, "reply", tracker->num_peers);
            } else if (const auto *tracker = lt::alert_cast<lt::tracker_warning_alert>(alert)) {
                record_tracker_event(*tracker, "warning");
            } else if (const auto *tracker = lt::alert_cast<lt::tracker_error_alert>(alert)) {
                record_tracker_event(
                    *tracker,
                    "error",
                    std::nullopt,
                    tracker->error.value(),
                    tracker->status_code > 0 ? std::optional<int>(tracker->status_code) : std::nullopt
                );
            } else if (const auto *reply = lt::alert_cast<lt::dht_reply_alert>(alert)) {
                record_dht_reply(*reply);
            } else if (lt::alert_cast<lt::dht_bootstrap_alert>(alert) != nullptr) {
                record_dht_bootstrap();
            } else if (const auto *error = lt::alert_cast<lt::dht_error_alert>(alert)) {
                record_dht_error(error->error.value());
            } else if (const auto *mapping = lt::alert_cast<lt::portmap_alert>(alert)) {
                record_port_mapping_success(*mapping);
            } else if (const auto *mapping = lt::alert_cast<lt::portmap_error_alert>(alert)) {
                record_port_mapping_error(*mapping);
            } else if (const auto *web_seed = lt::alert_cast<lt::url_seed_alert>(alert)) {
                std::fprintf(
                    stderr,
                    "[LibtorrentNative] web seed failure code=%d\n",
                    web_seed->error.value()
                );
            }
        }
    }

    void emit_tracker_diagnostics_json(
        std::ostringstream &json,
        const lt::torrent_handle &handle,
        const JobState::SwarmEvents &events
    ) const {
        struct TrackerSnapshot {
            std::optional<int> tier;
            std::optional<bool> is_verified;
            std::optional<int> consecutive_failures;
            std::optional<bool> is_updating;
            std::optional<std::string> last_event;
            std::optional<std::chrono::steady_clock::time_point> last_event_at;
            std::optional<int> last_response_peer_count;
            std::optional<int> last_error_code;
            std::optional<int> last_http_status_code;
        };

        std::unordered_map<std::string, TrackerSnapshot> snapshots;
        for (const auto &tracker : handle.trackers()) {
            const std::string endpoint = redact_tracker_endpoint(tracker.url);
            if (endpoint.empty()) {
                continue;
            }

            auto &snapshot = snapshots[endpoint];
            snapshot.tier = static_cast<int>(tracker.tier);
            snapshot.is_verified = tracker.verified;

            int failures = 0;
            bool updating = false;
            for (const auto &announce_endpoint : tracker.endpoints) {
                for (const auto &announce_info : announce_endpoint.info_hashes) {
                    failures = std::max(failures, static_cast<int>(announce_info.fails));
                    updating = updating || announce_info.updating;
                }
            }
            snapshot.consecutive_failures = failures;
            snapshot.is_updating = updating;
        }

        for (const auto &[endpoint, event] : events.trackers) {
            auto &snapshot = snapshots[endpoint];
            if (!event.last_event.empty()) {
                snapshot.last_event = event.last_event;
            }
            snapshot.last_event_at = event.last_event_at;
            snapshot.last_response_peer_count = event.last_response_peer_count;
            snapshot.last_error_code = event.last_error_code;
            snapshot.last_http_status_code = event.last_http_status_code;
        }

        std::vector<std::string> endpoints;
        endpoints.reserve(snapshots.size());
        for (const auto &[endpoint, _] : snapshots) {
            endpoints.push_back(endpoint);
        }
        std::sort(endpoints.begin(), endpoints.end());

        json << "[";
        for (std::size_t index = 0; index < endpoints.size(); ++index) {
            if (index > 0) {
                json << ",";
            }

            const auto &endpoint = endpoints[index];
            const auto &snapshot = snapshots.at(endpoint);
            json << "{\"endpoint\":\"" << json_escape(endpoint) << "\",";
            json << "\"tier\":";
            emit_optional_int_json(json, snapshot.tier);
            json << ",\"isVerified\":";
            emit_optional_bool_json(json, snapshot.is_verified);
            json << ",\"consecutiveFailures\":";
            emit_optional_int_json(json, snapshot.consecutive_failures);
            json << ",\"isUpdating\":";
            emit_optional_bool_json(json, snapshot.is_updating);
            json << ",\"lastEvent\":";
            emit_optional_string_json(json, snapshot.last_event);
            json << ",\"lastEventAgeSeconds\":";
            emit_optional_int_json(json, age_in_seconds(snapshot.last_event_at));
            json << ",\"lastResponsePeerCount\":";
            emit_optional_int_json(json, snapshot.last_response_peer_count);
            json << ",\"lastErrorCode\":";
            emit_optional_int_json(json, snapshot.last_error_code);
            json << ",\"lastHttpStatusCode\":";
            emit_optional_int_json(json, snapshot.last_http_status_code);
            json << "}";
        }
        json << "]";
    }

    void emit_port_mapping_diagnostics_json(std::ostringstream &json) const {
        const auto mappings = port_mapping_events();
        std::vector<int> indexes;
        indexes.reserve(mappings.size());
        for (const auto &[index, _] : mappings) {
            indexes.push_back(index);
        }
        std::sort(indexes.begin(), indexes.end());

        json << "[";
        for (std::size_t offset = 0; offset < indexes.size(); ++offset) {
            if (offset > 0) {
                json << ",";
            }

            const int index = indexes[offset];
            const auto &mapping = mappings.at(index);
            json << "{\"mappingIndex\":" << index << ",";
            json << "\"transport\":\"" << json_escape(mapping.transport) << "\",";
            json << "\"protocolName\":\"" << json_escape(mapping.protocol_name) << "\",";
            json << "\"status\":\"" << json_escape(mapping.status) << "\",";
            json << "\"lastEventAgeSeconds\":";
            emit_optional_int_json(json, age_in_seconds(mapping.last_event_at));
            json << ",\"lastErrorCode\":";
            emit_optional_int_json(json, mapping.last_error_code);
            json << "}";
        }
        json << "]";
    }

    void emit_swarm_diagnostics_json(
        std::ostringstream &json,
        const std::string &job_id,
        const lt::torrent_handle &handle,
        const lt::torrent_status &status
    ) const {
        const auto session_status = session_.status();
        const auto events = swarm_events_for(job_id);
        const auto dht = dht_events();
        const auto next_announce_seconds = static_cast<int>(std::max<std::int64_t>(
            0,
            std::chrono::duration_cast<std::chrono::seconds>(status.next_announce).count()
        ));

        json << "{\"connectedPeers\":" << status.num_peers << ",";
        json << "\"connectedSeeds\":" << status.num_seeds << ",";
        json << "\"connectionCount\":" << status.num_connections << ",";
        json << "\"knownPeers\":" << status.list_peers << ",";
        json << "\"knownSeeds\":" << status.list_seeds << ",";
        json << "\"connectCandidates\":" << status.connect_candidates << ",";
        json << "\"trackerReportedSeeds\":";
        emit_optional_int_json(json, non_negative_optional(status.num_complete));
        json << ",\"trackerReportedLeechers\":";
        emit_optional_int_json(json, non_negative_optional(status.num_incomplete));
        json << ",\"nextAnnounceInSeconds\":" << next_announce_seconds << ",";
        json << "\"hasIncomingConnections\":" << (session_status.has_incoming_connections ? "true" : "false") << ",";
        json << "\"trackers\":";
        emit_tracker_diagnostics_json(json, handle, events);
        json << ",\"dht\":{\"isRunning\":" << (session_.is_dht_running() ? "true" : "false") << ",";
        json << "\"nodeCount\":" << std::max(0, session_status.dht_nodes) << ",";
        json << "\"lastBootstrapAgeSeconds\":";
        emit_optional_int_json(json, age_in_seconds(dht.last_bootstrap_at));
        json << ",\"lastReplyPeerCount\":";
        emit_optional_int_json(json, events.last_dht_reply_peer_count);
        json << ",\"lastReplyAgeSeconds\":";
        emit_optional_int_json(json, age_in_seconds(events.last_dht_reply_at));
        json << ",\"lastErrorCode\":";
        emit_optional_int_json(json, dht.last_error_code);
        json << "},\"portMappings\":";
        emit_port_mapping_diagnostics_json(json);
        json << "}";
    }

    void pump_progress() {
        while (!stopping_.load()) {
            std::this_thread::sleep_for(std::chrono::seconds(1));
            process_alerts();

            std::vector<std::pair<std::string, lt::torrent_handle>> snapshot;
            {
                std::lock_guard<std::mutex> guard(lock_);
                for (auto &entry : jobs_) {
                    apply_pending_selection(entry.second.handle, entry.second);
                    snapshot.emplace_back(entry.first, entry.second.handle);
                }
            }

            for (const auto &entry : snapshot) {
                emit_progress(entry.first, entry.second, false);
            }
        }
    }

    void emit_progress(const std::string &job_id, const lt::torrent_handle &handle, bool force_completed) {
        if (callback_ == nullptr || !handle.is_valid()) {
            return;
        }

        lt::torrent_status status = handle.status();
        const bool completed = force_completed || status.is_finished;
        const double percent = completed ? 100.0 : status.progress_ppm / 10000.0;

        std::ostringstream json;
        json << "{\"type\":\"" << (completed ? "completed" : "progress") << "\",\"progress\":{";
        json << "\"jobId\":\"" << json_escape(job_id) << "\",";
        json << "\"status\":\"" << (completed ? "completed" : "downloading") << "\",";
        json << "\"name\":\"" << json_escape(status.name) << "\",";
        json << "\"bytesCompleted\":" << status.total_done << ",";
        json << "\"totalBytes\":" << status.total_wanted << ",";
        json << "\"percentComplete\":" << percent << ",";
        json << "\"bytesPerSecond\":" << status.download_payload_rate << ",";
        json << "\"totalBytesPerSecond\":" << status.download_rate << ",";
        json << "\"protocolBytesPerSecond\":"
             << std::max(0, status.download_rate - status.download_payload_rate) << ",";
        json << "\"peerCount\":" << status.num_peers << ",";
        json << "\"swarmDiagnostics\":";
        emit_swarm_diagnostics_json(json, job_id, handle, status);
        json << ",";
        json << "\"infoHash\":";
        emit_info_hash_json(json, handle);
        json << ",";
        json << "\"files\":";
        emit_files_json(json, handle);
        json << "}}";

        const auto payload = json.str();
        callback_(payload.c_str(), context_);
    }

    tryagi_libtorrent_event_callback_t callback_;
    void *context_;
    lt::session session_;
    std::atomic_bool stopping_{false};
    mutable std::mutex lock_;
    std::unordered_map<std::string, JobState> jobs_;
    DhtSessionEvents dht_events_;
    std::unordered_map<int, PortMappingEvent> port_mapping_events_;
    std::string last_error_;
    std::thread worker_;
};

NativeSession *as_session(void *session) {
    return reinterpret_cast<NativeSession *>(session);
}
} // namespace

int tryagi_libtorrent_session_create(
    tryagi_libtorrent_event_callback_t callback,
    void *context,
    void **session
) {
    if (session == nullptr) {
        return -1;
    }

    try {
        *session = new NativeSession(callback, context);
        return 0;
    } catch (...) {
        *session = nullptr;
        return -1;
    }
}

void tryagi_libtorrent_session_destroy(void *session) {
    delete as_session(session);
}

int tryagi_libtorrent_job_start(void *session, const char *json) {
    auto *native_session = as_session(session);
    return native_session == nullptr ? -1 : native_session->start(json);
}

int tryagi_libtorrent_job_apply_selection(void *session, const char *json) {
    auto *native_session = as_session(session);
    return native_session == nullptr ? -1 : native_session->apply_selection(json);
}

int tryagi_libtorrent_job_update_rate_limits(void *session, const char *json) {
    auto *native_session = as_session(session);
    return native_session == nullptr ? -1 : native_session->update_rate_limits(json);
}

int tryagi_libtorrent_job_reannounce(void *session, const char *json) {
    auto *native_session = as_session(session);
    return native_session == nullptr ? -1 : native_session->reannounce(json);
}

int tryagi_libtorrent_job_refresh_peers(void *session, const char *json) {
    auto *native_session = as_session(session);
    return native_session == nullptr ? -1 : native_session->refresh_peers(json);
}

int tryagi_libtorrent_job_pause(void *session, const char *json) {
    auto *native_session = as_session(session);
    return native_session == nullptr ? -1 : native_session->pause(json);
}

int tryagi_libtorrent_job_resume(void *session, const char *json) {
    auto *native_session = as_session(session);
    return native_session == nullptr ? -1 : native_session->resume(json);
}

int tryagi_libtorrent_job_cancel(void *session, const char *json) {
    auto *native_session = as_session(session);
    return native_session == nullptr ? -1 : native_session->cancel(json);
}

const char *tryagi_libtorrent_last_error(void *session) {
    auto *native_session = as_session(session);
    return native_session == nullptr ? nullptr : native_session->last_error();
}
