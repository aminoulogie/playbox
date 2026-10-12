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
#include <cmath>
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
    bool prewarm = false;
};

struct JobState {
    std::string job_id;
    lt::torrent_handle handle;
    std::optional<FileSelection> pending_selection;
    std::optional<int> primary_file_index;
    bool file_selection_applied = false;
    std::string download_directory;
    bool completed_sent = false;
    bool stream_ready_sent = false;
    // Prewarm jobs fetch metadata and keep peers connected without
    // downloading file data. A later Play job for the same torrent adopts them.
    bool prewarm = false;
    bool prewarm_files_blocked = false;
    std::optional<double> playback_position;
    bool playback_priorities_initialized = false;
    int streaming_anchor_piece = -1;
    int streaming_window_first = -1;
    int streaming_window_last = -1;
    std::vector<int> streaming_priority_pieces;
    std::vector<int> streaming_deadline_pieces;
    bool progress_dirty = true;
    std::optional<std::chrono::steady_clock::time_point> last_progress_poll;
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

std::string file_path_to_url(const std::string &path) {
    std::ostringstream output;
    output << "file://";
    static constexpr char hex[] = "0123456789ABCDEF";
    for (const unsigned char ch : path) {
        const bool safe =
            (ch >= 'a' && ch <= 'z') ||
            (ch >= 'A' && ch <= 'Z') ||
            (ch >= '0' && ch <= '9') ||
            ch == '/' || ch == '-' || ch == '_' || ch == '.' || ch == '~';
        if (safe) {
            output << ch;
        } else {
            output << '%' << hex[(ch >> 4) & 0x0f] << hex[ch & 0x0f];
        }
    }
    return output.str();
}

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

std::optional<double> extract_json_double(const std::string &json, const std::string &key) {
    const std::string needle = "\"" + key + "\"";
    const auto key_position = json.find(needle);
    if (key_position == std::string::npos) {
        return std::nullopt;
    }

    const auto colon = json.find(':', key_position + needle.size());
    if (colon == std::string::npos) {
        return std::nullopt;
    }
    const char *start = json.c_str() + colon + 1;
    while (*start != '\0' && std::isspace(static_cast<unsigned char>(*start))) {
        ++start;
    }
    char *end = nullptr;
    const double value = std::strtod(start, &end);
    if (end == start || !std::isfinite(value)) {
        return std::nullopt;
    }
    while (*end != '\0' && std::isspace(static_cast<unsigned char>(*end))) {
        ++end;
    }
    if (*end != ',' && *end != '}' && *end != '\0') {
        return std::nullopt;
    }
    return value;
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
    request.prewarm = extract_json_bool(request_json, "prewarm").value_or(false);
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

    // Streaming-first tuning: reach many peers quickly, drop slow ones fast,
    // and keep deep request queues so the playhead pieces arrive sooner.
    settings.set_bool(lt::settings_pack::announce_to_all_trackers, true);
    settings.set_bool(lt::settings_pack::announce_to_all_tiers, true);
    settings.set_bool(lt::settings_pack::smooth_connects, false);
    settings.set_bool(lt::settings_pack::close_redundant_connections, false);
    settings.set_bool(lt::settings_pack::strict_end_game_mode, false);
    settings.set_int(lt::settings_pack::connections_limit, 400);
    settings.set_int(lt::settings_pack::connection_speed, 100);
    settings.set_int(lt::settings_pack::torrent_connect_boost, 60);
    settings.set_int(lt::settings_pack::peer_connect_timeout, 7);
    settings.set_int(lt::settings_pack::handshake_timeout, 7);
    settings.set_int(lt::settings_pack::min_reconnect_time, 5);
    settings.set_int(lt::settings_pack::request_timeout, 10);
    settings.set_int(lt::settings_pack::piece_timeout, 10);
    settings.set_int(lt::settings_pack::request_queue_time, 2);
    settings.set_int(lt::settings_pack::max_out_request_queue, 1500);
    settings.set_int(lt::settings_pack::max_allowed_in_request_queue, 2000);
    settings.set_int(lt::settings_pack::max_peerlist_size, 4000);
    settings.set_int(lt::settings_pack::min_announce_interval, 30);
    settings.set_int(lt::settings_pack::dht_announce_interval, 60);
    settings.set_int(lt::settings_pack::active_downloads, 8);
    settings.set_int(lt::settings_pack::active_limit, 16);
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

std::optional<std::pair<int, int>> file_piece_span(
    const lt::torrent_handle &handle,
    int file_index
) {
    const auto torrent_info = handle.torrent_file();
    if (!torrent_info) {
        return std::nullopt;
    }

    const auto &files = torrent_info->files();
    if (file_index < 0 || file_index >= files.num_files()) {
        return std::nullopt;
    }

    const lt::file_index_t index{file_index};
    const auto size = files.file_size(index);
    if (size <= 0) {
        return std::nullopt;
    }

    const auto offset = files.file_offset(index);
    const auto piece_length = std::max(1, torrent_info->piece_length());
    const int first = static_cast<int>(offset / piece_length);
    const int last = static_cast<int>((offset + size - 1) / piece_length);
    return std::make_pair(first, last);
}

bool piece_available(const lt::torrent_status &status, int piece) {
    return status.is_seeding || (
        piece >= 0 && piece < status.pieces.size() &&
        status.pieces[lt::piece_index_t{piece}]
    );
}

std::int64_t playback_byte_offset(std::int64_t file_size, double progress) {
    if (file_size <= 0) {
        return 0;
    }
    // Time and byte positions differ in variable bitrate media. This is an
    // estimate until the player can report exact file read offsets.
    const long double estimated = static_cast<long double>(file_size) *
        std::clamp(progress, 0.0, 1.0);
    return static_cast<std::int64_t>(std::min<long double>(file_size - 1, estimated));
}

std::int64_t contiguous_file_bytes(
    const lt::torrent_handle &handle,
    int file_index,
    const lt::torrent_status &status,
    std::int64_t requested_offset = 0
) {
    const auto torrent_info = handle.torrent_file();
    const auto span = file_piece_span(handle, file_index);
    if (!torrent_info || !span.has_value()) {
        return 0;
    }

    const auto &files = torrent_info->files();
    const lt::file_index_t index{file_index};
    const std::int64_t file_offset = files.file_offset(index);
    const std::int64_t file_size = files.file_size(index);
    const std::int64_t local_offset = std::clamp<std::int64_t>(requested_offset, 0, file_size);
    const std::int64_t range_start = file_offset + local_offset;
    const std::int64_t file_end = file_offset + file_size;
    const auto piece_length = std::max(1, torrent_info->piece_length());
    const int first = static_cast<int>(range_start / piece_length);

    std::int64_t contiguous = 0;
    for (int piece = first; piece <= span->second; ++piece) {
        if (!piece_available(status, piece)) {
            break;
        }
        const lt::piece_index_t piece_index{piece};
        const std::int64_t piece_start = static_cast<std::int64_t>(piece) * piece_length;
        const std::int64_t piece_end = piece_start + torrent_info->piece_size(piece_index);
        const std::int64_t overlap_start = std::max(range_start, piece_start);
        const std::int64_t overlap_end = std::min(file_end, piece_end);
        if (overlap_end > overlap_start) {
            contiguous += overlap_end - overlap_start;
        }
    }
    return std::min(contiguous, file_size - local_offset);
}

bool tail_ready_for_container(
    const lt::torrent_handle &handle,
    int file_index,
    std::int64_t tail_bytes,
    const lt::torrent_status &status
) {
    const auto torrent_info = handle.torrent_file();
    if (!torrent_info) {
        return false;
    }

    const auto &files = torrent_info->files();
    if (file_index < 0 || file_index >= files.num_files()) {
        return false;
    }

    const lt::file_index_t index{file_index};
    const auto size = files.file_size(index);
    const auto offset = files.file_offset(index);
    if (size <= 0) {
        return false;
    }

    const auto piece_length = std::max(1, torrent_info->piece_length());
    const auto start_offset = offset + std::max<std::int64_t>(0, size - tail_bytes);
    const int first = static_cast<int>(start_offset / piece_length);
    const int last = static_cast<int>((offset + size - 1) / piece_length);

    for (int piece = first; piece <= last; ++piece) {
        if (!piece_available(status, piece)) {
            return false;
        }
    }
    return true;
}

double tail_download_progress(
    const lt::torrent_handle &handle,
    int file_index,
    std::int64_t tail_bytes,
    const lt::torrent_status &status
) {
    const auto torrent_info = handle.torrent_file();
    if (!torrent_info) {
        return 0.0;
    }

    const auto &files = torrent_info->files();
    if (file_index < 0 || file_index >= files.num_files()) {
        return 0.0;
    }

    const lt::file_index_t index{file_index};
    const auto size = files.file_size(index);
    const auto offset = files.file_offset(index);
    if (size <= 0) {
        return 0.0;
    }

    const auto piece_length = std::max(1, torrent_info->piece_length());
    const auto start_offset = offset + std::max<std::int64_t>(0, size - tail_bytes);
    const int first = static_cast<int>(start_offset / piece_length);
    const int last = static_cast<int>((offset + size - 1) / piece_length);
    const int total = std::max(1, last - first + 1);

    int complete = 0;
    for (int piece = first; piece <= last; ++piece) {
        if (piece_available(status, piece)) {
            ++complete;
        }
    }

    return std::clamp(
        static_cast<double>(complete) / static_cast<double>(total),
        0.0,
        1.0
    );
}

bool file_needs_tail_metadata(const std::string &path) {
    const auto dot = path.find_last_of('.');
    if (dot == std::string::npos) {
        return false;
    }
    std::string ext = path.substr(dot + 1);
    std::transform(ext.begin(), ext.end(), ext.begin(), [](unsigned char ch) {
        return static_cast<char>(std::tolower(ch));
    });
    return ext == "mp4" || ext == "m4v" || ext == "mov";
}

constexpr std::int64_t kStartupBufferFloor = 256LL * 1024LL;
constexpr std::int64_t kStartupBufferDefault = 512LL * 1024LL;
constexpr std::int64_t kStartupBufferCeiling = 1024LL * 1024LL;
constexpr std::int64_t kContainerMetadataBytes = 1024LL * 1024LL;

// Fast swarms start almost immediately; slow ones wait for a larger head so
// VLC does not stall right after the first frame.
std::int64_t startup_buffer_target(std::int64_t file_size, int payload_bytes_per_second) {
    std::int64_t target = kStartupBufferDefault;
    if (payload_bytes_per_second >= 1024 * 1024) {
        target = kStartupBufferFloor;
    } else if (payload_bytes_per_second < 200 * 1024) {
        target = kStartupBufferCeiling;
    }
    return std::max<std::int64_t>(0, std::min(file_size, target));
}

void invalidate_streaming_priorities(JobState &state) {
    state.playback_priorities_initialized = false;
    state.streaming_anchor_piece = -1;
    state.streaming_window_first = -1;
    state.streaming_window_last = -1;
    state.streaming_priority_pieces.clear();
    state.streaming_deadline_pieces.clear();
    state.progress_dirty = true;
}

void maintain_streaming_priorities(
    lt::torrent_handle &handle,
    JobState &state,
    const lt::torrent_status &status
) {
    if (!state.primary_file_index.has_value()) {
        return;
    }

    const int file_index = *state.primary_file_index;
    const auto torrent_info = handle.torrent_file();
    const auto span = file_piece_span(handle, file_index);
    if (!torrent_info || !span.has_value()) {
        return;
    }

    const auto &files = torrent_info->files();
    const lt::file_index_t index{file_index};
    const auto size = files.file_size(index);
    const auto file_offset = files.file_offset(index);
    const auto piece_length = std::max(1, torrent_info->piece_length());
    const bool following_playback = state.playback_position.has_value();
    const auto requested_offset = following_playback
        ? playback_byte_offset(size, *state.playback_position)
        : 0;
    const int anchor = static_cast<int>((file_offset + requested_offset) / piece_length);

    // Use one bitmap snapshot rather than synchronously querying each piece.
    int frontier = anchor;
    while (frontier <= span->second && piece_available(status, frontier)) {
        ++frontier;
    }
    const int window_last = std::min(span->second, frontier + 96);
    const int lookbehind_first = std::max(span->first, anchor - 4);

    std::vector<int> priorities;
    std::unordered_map<int, int> deadlines;
    const auto add_range = [&](int first, int last, int base_ms, int step_ms) {
        for (int piece = first; piece <= last; ++piece) {
            priorities.push_back(piece);
            if (!piece_available(status, piece)) {
                const int due_ms = base_ms + (piece - first) * step_ms;
                const auto result = deadlines.emplace(piece, due_ms);
                if (!result.second) {
                    result.first->second = std::min(result.first->second, due_ms);
                }
            }
        }
    };
    // The first pieces past the frontier are due almost immediately so the
    // time-critical picker requests them from the fastest peers first.
    add_range(frontier, std::min(window_last, frontier + 3), 0, 50);
    add_range(frontier, window_last, 200, 150);
    if (following_playback) {
        // Decoder seeks may read the keyframe immediately before the target.
        add_range(lookbehind_first, anchor, 100, 20);
        // Keep the startup header available after a seek away from the start.
        const auto head_end = file_offset + std::min<std::int64_t>(size, kContainerMetadataBytes) - 1;
        const int head_last = static_cast<int>(head_end / piece_length);
        add_range(span->first, head_last, 25, 20);
    }
    if (file_needs_tail_metadata(files.file_path(index))) {
        const auto tail_start = file_offset + std::max<std::int64_t>(0, size - kContainerMetadataBytes);
        add_range(static_cast<int>(tail_start / piece_length), span->second, 25, 20);
    }
    std::sort(priorities.begin(), priorities.end());
    priorities.erase(std::unique(priorities.begin(), priorities.end()), priorities.end());

    using PiecePriority = std::pair<lt::piece_index_t, lt::download_priority_t>;
    std::vector<PiecePriority> changes;
    if (following_playback && !state.playback_priorities_initialized) {
        // File selection marks the entire primary file top priority. Lower
        // only its pieces so the moving playback window actually wins.
        changes.reserve(static_cast<std::size_t>(span->second - span->first + 1));
        for (int piece = span->first; piece <= span->second; ++piece) {
            const bool urgent = std::binary_search(priorities.begin(), priorities.end(), piece);
            changes.emplace_back(
                lt::piece_index_t{piece},
                urgent ? lt::top_priority : lt::default_priority
            );
        }
        state.playback_priorities_initialized = true;
    } else {
        if (following_playback) {
            for (const int piece : state.streaming_priority_pieces) {
                if (!std::binary_search(priorities.begin(), priorities.end(), piece)) {
                    changes.emplace_back(lt::piece_index_t{piece}, lt::default_priority);
                }
            }
        }
        for (const int piece : priorities) {
            if (!std::binary_search(
                state.streaming_priority_pieces.begin(),
                state.streaming_priority_pieces.end(),
                piece
            )) {
                changes.emplace_back(lt::piece_index_t{piece}, lt::top_priority);
            }
        }
    }
    if (!changes.empty()) {
        // This overload leaves every other selected/unselected file untouched.
        handle.prioritize_pieces(changes);
    }

    std::vector<int> deadline_pieces;
    deadline_pieces.reserve(deadlines.size());
    for (const auto &[piece, _] : deadlines) {
        deadline_pieces.push_back(piece);
    }
    std::sort(deadline_pieces.begin(), deadline_pieces.end());
    // Only a playhead jump invalidates every deadline. The frontier advancing
    // as pieces arrive must not cancel in-flight time-critical requests.
    const bool window_changed = state.streaming_anchor_piece != anchor;
    if (window_changed) {
        // Seek deadlines from the previous position must not compete with the
        // new position. Head/tail requirements are reapplied below.
        handle.clear_piece_deadlines();
    } else {
        for (const int piece : state.streaming_deadline_pieces) {
            if (!std::binary_search(deadline_pieces.begin(), deadline_pieces.end(), piece)) {
                handle.reset_piece_deadline(lt::piece_index_t{piece});
            }
        }
    }
    for (const auto &[piece, due_ms] : deadlines) {
        if (window_changed || !std::binary_search(
            state.streaming_deadline_pieces.begin(),
            state.streaming_deadline_pieces.end(),
            piece
        )) {
            handle.set_piece_deadline(lt::piece_index_t{piece}, due_ms);
        }
    }

    state.streaming_anchor_piece = anchor;
    state.streaming_window_first = frontier;
    state.streaming_window_last = window_last;
    state.streaming_priority_pieces = std::move(priorities);
    state.streaming_deadline_pieces = std::move(deadline_pieces);
}

bool apply_pending_selection(lt::torrent_handle &handle, JobState &state) {
    if (!state.pending_selection.has_value()) {
        return true;
    }
    if (!apply_file_selection(handle, *state.pending_selection)) {
        return false;
    }
    state.primary_file_index = state.pending_selection->primary_file_index;
    state.pending_selection.reset();
    state.file_selection_applied = true;
    invalidate_streaming_priorities(state);
    state.stream_ready_sent = false;
    state.completed_sent = false;
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
            if (awaiting_selection || request.prewarm) {
                // Magnets have no file count yet; libtorrent trims the vector
                // to the real count once metadata arrives.
                const std::size_t count = params.ti
                    ? static_cast<std::size_t>(params.ti->num_files())
                    : 4096;
                params.file_priorities.assign(count, lt::dont_download);
            }

            // A prewarm for a torrent that is already running has nothing to do,
            // and must never lower the running job's file priorities.
            if (request.prewarm && torrent_exists(params.info_hashes, params.ti)) {
                return 0;
            }

            // Reuse a prewarmed (or still running) torrent with the same info
            // hash: its metadata, DHT state and peer connections are already warm.
            lt::torrent_handle handle = adopt_existing_torrent(params.info_hashes, params.ti);
            if (!handle.is_valid()) {
                lt::error_code error;
                handle = session_.add_torrent(std::move(params), error);
                if (error) {
                    return fail("failed to add torrent: " + error.message());
                }
            } else if (!request.prewarm) {
                handle.resume();
                handle.force_dht_announce();
            }
            apply_rate_limits(handle, request);
            auto pending_selection = request.selection;
            if (pending_selection.has_value() && apply_file_selection(handle, *pending_selection)) {
                pending_selection.reset();
            }

            {
                JobState state;
                state.job_id = request.job_id;
                state.handle = handle;
                state.prewarm = request.prewarm;
                state.pending_selection = pending_selection;
                state.file_selection_applied = request.selection.has_value() && !pending_selection.has_value();
                state.download_directory = request.download_directory;
                if (request.selection.has_value()) {
                    state.primary_file_index = request.selection->primary_file_index;
                }

                std::lock_guard<std::mutex> guard(lock_);
                jobs_[request.job_id] = std::move(state);
            }
            if (!request.prewarm) {
                emit_progress(request.job_id, handle);
            }
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
            // fail() also takes lock_; store the error directly while locked.
            last_error_ = "selection request references an unknown jobId";
            return -1;
        }
        iterator->second.pending_selection = selection;
        iterator->second.stream_ready_sent = false;
        iterator->second.handle.clear_piece_deadlines();
        invalidate_streaming_priorities(iterator->second);
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

    int update_playback_position(const char *json) {
        const std::string request_json = json == nullptr ? "" : json;
        const auto job_id = parse_job_id(json);
        const auto progress = extract_json_double(request_json, "progress");
        if (job_id.empty() || !progress.has_value()) {
            return fail("playback position request requires jobId and finite progress");
        }

        std::lock_guard<std::mutex> guard(lock_);
        auto iterator = jobs_.find(job_id);
        if (iterator == jobs_.end()) {
            last_error_ = "playback position request references an unknown jobId";
            return -1;
        }
        // Accept before metadata arrives; selection and the worker apply the
        // request as soon as the primary file is known.
        iterator->second.playback_position = std::clamp(*progress, 0.0, 1.0);
        iterator->second.progress_dirty = true;
        return 0;
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
                last_error_ = "cancel request references an unknown jobId";
                return -1;
            }
            handle = iterator->second.handle;
            jobs_.erase(iterator);
            // An adopted torrent may still back another job.
            for (const auto &[_, other] : jobs_) {
                if (other.handle == handle) {
                    return 0;
                }
            }
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
    bool torrent_exists(
        const lt::info_hash_t &hashes,
        const std::shared_ptr<const lt::torrent_info> &info
    ) const {
        lt::info_hash_t lookup = hashes;
        if (!lookup.has_v1() && !lookup.has_v2() && info) {
            lookup = info->info_hashes();
        }
        return (lookup.has_v1() || lookup.has_v2())
            && session_.find_torrent(lookup.get_best()).is_valid();
    }

    lt::torrent_handle adopt_existing_torrent(
        const lt::info_hash_t &hashes,
        const std::shared_ptr<const lt::torrent_info> &info
    ) {
        lt::info_hash_t lookup = hashes;
        if (!lookup.has_v1() && !lookup.has_v2() && info) {
            lookup = info->info_hashes();
        }
        if (!lookup.has_v1() && !lookup.has_v2()) {
            return {};
        }
        auto existing = session_.find_torrent(lookup.get_best());
        if (!existing.is_valid()) {
            return {};
        }

        std::lock_guard<std::mutex> guard(lock_);
        for (auto iterator = jobs_.begin(); iterator != jobs_.end();) {
            if (iterator->second.handle == existing && iterator->second.prewarm) {
                iterator = jobs_.erase(iterator);
            } else {
                ++iterator;
            }
        }
        // A non-prewarm job still owns this torrent; adding again would fail
        // with a duplicate error, so share the handle.
        return existing;
    }

    void block_prewarm_file_data(JobState &state) {
        if (state.prewarm_files_blocked || !state.handle.is_valid()) {
            return;
        }
        const auto info = state.handle.torrent_file();
        if (!info) {
            return;
        }
        state.handle.prioritize_files(std::vector<lt::download_priority_t>(
            static_cast<std::size_t>(info->num_files()),
            lt::dont_download
        ));
        state.prewarm_files_blocked = true;
    }

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
                last_error_ = "control request references an unknown jobId";
                return -1;
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

    void record_file_priorities_applied(const lt::torrent_handle &handle) {
        std::lock_guard<std::mutex> guard(lock_);
        for (auto &[_, state] : jobs_) {
            if (state.handle == handle) {
                // File priorities finish asynchronously and reset piece
                // overrides. Rebuild even when the playhead has not moved.
                invalidate_streaming_priorities(state);
            }
        }
    }

    void emit_completed_for_handle(const lt::torrent_handle &handle) {
        std::vector<std::string> job_ids;
        {
            std::lock_guard<std::mutex> guard(lock_);
            for (const auto &[job_id, state] : jobs_) {
                if (state.handle == handle) {
                    job_ids.push_back(job_id);
                }
            }
        }
        if (!handle.is_valid()) {
            return;
        }
        const auto status = handle.status();
        for (const auto &job_id : job_ids) {
            emit_stream_ready_if_possible(job_id, handle, status);
            emit_progress(job_id, handle, &status);
        }
    }

    void process_alerts() {
        std::vector<lt::alert *> alerts;
        session_.pop_alerts(&alerts);

        for (const auto *alert : alerts) {
            if (const auto *priority = lt::alert_cast<lt::file_prio_alert>(alert)) {
                record_file_priorities_applied(priority->handle);
            } else if (const auto *finished = lt::alert_cast<lt::torrent_finished_alert>(alert)) {
                emit_completed_for_handle(finished->handle);
            } else if (const auto *tracker = lt::alert_cast<lt::tracker_announce_alert>(alert)) {
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
            std::this_thread::sleep_for(std::chrono::milliseconds(20));
            process_alerts();

            const auto now = std::chrono::steady_clock::now();
            std::vector<std::pair<std::string, lt::torrent_handle>> snapshot;
            {
                std::lock_guard<std::mutex> guard(lock_);
                for (auto &[job_id, state] : jobs_) {
                    if (state.prewarm) {
                        block_prewarm_file_data(state);
                        continue;
                    }
                    if (state.completed_sent && !state.progress_dirty) {
                        continue;
                    }
                    const bool due = !state.last_progress_poll.has_value() ||
                        now - *state.last_progress_poll >= std::chrono::milliseconds(100);
                    if (!due && !state.progress_dirty) {
                        continue;
                    }
                    apply_pending_selection(state.handle, state);
                    state.progress_dirty = false;
                    state.last_progress_poll = now;
                    snapshot.emplace_back(job_id, state.handle);
                }
            }

            for (const auto &[job_id, handle] : snapshot) {
                if (!handle.is_valid()) {
                    continue;
                }
                const auto status = handle.status();
                {
                    std::lock_guard<std::mutex> guard(lock_);
                    const auto iterator = jobs_.find(job_id);
                    if (iterator == jobs_.end()) {
                        continue;
                    }
                    maintain_streaming_priorities(iterator->second.handle, iterator->second, status);
                }
                emit_stream_ready_if_possible(job_id, handle, status);
                emit_progress(job_id, handle, &status);
            }
        }
    }

    void emit_stream_ready_if_possible(
        const std::string &job_id,
        const lt::torrent_handle &handle,
        const lt::torrent_status &status
    ) {
        if (callback_ == nullptr || !handle.is_valid()) {
            return;
        }

        std::optional<int> primary_index;
        std::string download_directory;
        bool already_sent = false;
        {
            std::lock_guard<std::mutex> guard(lock_);
            const auto iterator = jobs_.find(job_id);
            if (iterator == jobs_.end()) {
                return;
            }
            primary_index = iterator->second.primary_file_index;
            download_directory = iterator->second.download_directory;
            already_sent = iterator->second.stream_ready_sent;
        }

        if (already_sent || !primary_index.has_value()) {
            return;
        }

        const auto torrent_info = handle.torrent_file();
        if (!torrent_info) {
            return;
        }

        const auto &files = torrent_info->files();
        const int file_index = *primary_index;
        if (file_index < 0 || file_index >= files.num_files()) {
            return;
        }

        const lt::file_index_t index{file_index};
        const auto file_size = files.file_size(index);
        const auto available = contiguous_file_bytes(handle, file_index, status);
        const std::int64_t startup_target = startup_buffer_target(
            file_size,
            status.download_payload_rate
        );

        const std::string relative_path = files.file_path(index);
        const bool tail_required = file_needs_tail_metadata(relative_path);
        const bool tail_ready = !tail_required || tail_ready_for_container(
            handle,
            file_index,
            kContainerMetadataBytes,
            status
        );

        if (available < startup_target || !tail_ready) {
            return;
        }

        {
            std::lock_guard<std::mutex> guard(lock_);
            auto iterator = jobs_.find(job_id);
            if (iterator == jobs_.end() || iterator->second.stream_ready_sent) {
                return;
            }
            iterator->second.stream_ready_sent = true;
        }

        std::string absolute_path = download_directory;
        if (!absolute_path.empty() && absolute_path.back() != '/') {
            absolute_path.push_back('/');
        }
        absolute_path += relative_path;

        std::ostringstream json;
        json << "{\"type\":\"stream_ready\",\"readiness\":{";
        json << "\"jobId\":\"" << json_escape(job_id) << "\",";
        json << "\"primaryFileIndex\":" << file_index << ",";
        json << "\"fileURL\":\"" << json_escape(file_path_to_url(absolute_path)) << "\",";
        json << "\"bytesAvailable\":" << available << ",";
        json << "\"totalBytes\":" << file_size;
        json << "}}";

        const auto payload = json.str();
        callback_(payload.c_str(), context_);
    }

    void emit_progress(
        const std::string &job_id,
        const lt::torrent_handle &handle,
        const lt::torrent_status *status_snapshot = nullptr
    ) {
        if (callback_ == nullptr || !handle.is_valid()) {
            return;
        }

        const auto status = status_snapshot == nullptr ? handle.status() : *status_snapshot;
        std::optional<int> completion_primary;
        bool completion_selection_applied = false;
        {
            std::lock_guard<std::mutex> guard(lock_);
            const auto iterator = jobs_.find(job_id);
            if (iterator == jobs_.end()) {
                return;
            }
            if (!iterator->second.pending_selection.has_value()) {
                completion_primary = iterator->second.primary_file_index;
                completion_selection_applied = iterator->second.file_selection_applied;
            }
        }
        bool completed = false;
        if (status.is_finished && status.total_wanted > 0 && completion_selection_applied) {
            // Explicit Download selections may have no primary file.
            completed = !completion_primary.has_value();
            if (completion_primary.has_value()) {
                if (const auto info = handle.torrent_file()) {
                    const auto &files = info->files();
                    const int primary = *completion_primary;
                    if (primary >= 0 && primary < files.num_files()) {
                        const auto size = files.file_size(lt::file_index_t{primary});
                        // is_finished can mean zero wanted files or a previous
                        // asynchronous selection. Require the actual primary data.
                        completed = size > 0 &&
                            contiguous_file_bytes(handle, primary, status) >= size;
                    }
                }
            }
        }
        if (completed) {
            std::lock_guard<std::mutex> guard(lock_);
            const auto iterator = jobs_.find(job_id);
            if (iterator == jobs_.end() || iterator->second.completed_sent) {
                return;
            }
            iterator->second.completed_sent = true;
        }
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

        std::int64_t streaming_buffered_bytes = 0;
        std::int64_t streaming_buffer_target_bytes = 0;
        double streaming_ready_percent = 0.0;
        std::optional<double> playback_position;
        std::optional<std::int64_t> playback_buffered_bytes;
        std::optional<std::int64_t> playback_buffer_target_bytes;
        {
            std::lock_guard<std::mutex> guard(lock_);
            const auto iterator = jobs_.find(job_id);
            if (iterator != jobs_.end()) {
                playback_position = iterator->second.playback_position;
            }
            if (iterator != jobs_.end() && iterator->second.primary_file_index.has_value()) {
                const int primary = *iterator->second.primary_file_index;
                streaming_buffered_bytes = contiguous_file_bytes(handle, primary, status);
                if (const auto info = handle.torrent_file()) {
                    const auto &files = info->files();
                    if (primary >= 0 && primary < files.num_files()) {
                        const lt::file_index_t file_index{primary};
                        const auto file_size = files.file_size(file_index);
                        if (playback_position.has_value() && file_size > 0) {
                            const auto offset = playback_byte_offset(file_size, *playback_position);
                            playback_buffered_bytes = contiguous_file_bytes(handle, primary, status, offset);
                            playback_buffer_target_bytes = startup_buffer_target(
                                file_size - offset,
                                status.download_payload_rate
                            );
                        }
                        streaming_buffer_target_bytes = startup_buffer_target(
                            file_size,
                            status.download_payload_rate
                        );

                        const double head_progress = streaming_buffer_target_bytes > 0
                            ? std::clamp(
                                static_cast<double>(streaming_buffered_bytes) /
                                    static_cast<double>(streaming_buffer_target_bytes),
                                0.0,
                                1.0
                            )
                            : 0.0;

                        const std::string path = files.file_path(file_index);
                        if (file_needs_tail_metadata(path)) {
                            const double tail_progress = tail_download_progress(
                                handle,
                                primary,
                                kContainerMetadataBytes,
                                status
                            );
                            streaming_ready_percent =
                                (head_progress * 0.70 + tail_progress * 0.30) * 100.0;
                        } else {
                            streaming_ready_percent = head_progress * 100.0;
                        }
                    }
                }
            }
        }
        json << "\"streamingBufferedBytes\":" << streaming_buffered_bytes << ",";
        json << "\"streamingBufferTargetBytes\":" << streaming_buffer_target_bytes << ",";
        json << "\"streamingReadyPercent\":" << streaming_ready_percent << ",";
        json << "\"playbackPosition\":";
        if (playback_position.has_value()) {
            json << std::setprecision(17) << *playback_position;
        } else {
            json << "null";
        }
        json << ",\"playbackBufferedBytes\":";
        if (playback_buffered_bytes.has_value()) {
            json << *playback_buffered_bytes;
        } else {
            json << "null";
        }
        json << ",\"playbackBufferTargetBytes\":";
        if (playback_buffer_target_bytes.has_value()) {
            json << *playback_buffer_target_bytes;
        } else {
            json << "null";
        }
        json << ",";
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

int tryagi_libtorrent_job_update_playback_position(void *session, const char *json) {
    auto *native_session = as_session(session);
    return native_session == nullptr ? -1 : native_session->update_playback_position(json);
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
