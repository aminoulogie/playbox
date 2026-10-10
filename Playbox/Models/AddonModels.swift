import Foundation

struct AddonManifest: Codable, Identifiable {
    let id: String
    let version: String?
    let name: String
    let description: String?
    // The add-on protocol permits resources as strings or descriptor objects.
    let resources: [AddonResource]?
    let types: [String]?
    let catalogs: [AddonCatalog]?
}

enum AddonResource: Codable, Hashable {
    case name(String)
    case descriptor(AddonResourceDescriptor)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let name = try? container.decode(String.self) {
            self = .name(name)
        } else {
            self = .descriptor(try container.decode(AddonResourceDescriptor.self))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .name(let name): try container.encode(name)
        case .descriptor(let descriptor): try container.encode(descriptor)
        }
    }
}

struct AddonResourceDescriptor: Codable, Hashable {
    let name: String
    let types: [String]?
    let idPrefixes: [String]?
}

struct AddonCatalog: Codable, Hashable {
    let type: String
    let id: String
    let name: String?
}

struct MetaPreview: Codable, Identifiable, Hashable {
    let id: String
    let type: String
    let name: String
    let poster: String?
    let description: String?
    let imdbRating: String?
    let releaseInfo: String?
    let genres: [String]?
    let runtime: String?
    let background: String?
    let videos: [MetaVideo]?
}

struct MetaVideo: Codable, Identifiable, Hashable {
    let id: String
    let title: String?
    let season: Int?
    let episode: Int?
    let released: String?
    let overview: String?
    let thumbnail: String?
    let runtime: String?
}

struct MetaResponse: Codable { let meta: MetaPreview }
struct CatalogResponse: Codable { let metas: [MetaPreview] }
struct StreamResponse: Codable { let streams: [AddonStream] }

struct SubtitleResponse: Codable { let subtitles: [AddonSubtitle] }

struct AddonSubtitle: Codable, Identifiable, Hashable {
    let id: String?
    let url: String
    let lang: String?

    var stableID: String { id ?? url }
}

struct AddonStream: Codable, Identifiable, Hashable {
    let name: String?
    let title: String?
    let url: String?
    let infoHash: String?
    let fileIdx: Int?
    let sources: [String]?

    var id: String {
        [name, title, url, infoHash, fileIdx.map(String.init), sources?.joined(separator: ",")]
            .compactMap { $0 }.joined(separator: "|")
    }

    var playableURL: URL? {
        guard let raw = url?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        let encoded = raw.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? raw
        guard let value = URL(string: encoded),
              ["http", "https"].contains(value.scheme?.lowercased() ?? "") else { return nil }
        return value
    }

    var playbackStatus: String {
        if playableURL != nil { return "Direct stream · Tap to play" }
        if isTorrent { return "Torrent source · Play or download" }
        return "Unsupported stream URL"
    }

    var isTorrent: Bool {
        infoHash != nil || url?.lowercased().hasPrefix("magnet:") == true
    }

    var torrentMagnetURI: String? {
        if let raw = url?.trimmingCharacters(in: .whitespacesAndNewlines),
           raw.lowercased().hasPrefix("magnet:") {
            return magnetURIByMergingTrackers(raw)
        }

        guard let infoHash = infoHash?.trimmingCharacters(in: .whitespacesAndNewlines),
              !infoHash.isEmpty else { return nil }

        var components = URLComponents()
        components.scheme = "magnet"

        var queryItems = [
            URLQueryItem(name: "xt", value: "urn:btih:\(infoHash)")
        ]

        if let displayName = title ?? name, !displayName.isEmpty {
            queryItems.append(URLQueryItem(name: "dn", value: displayName))
        }

        for tracker in torrentTrackers {
            queryItems.append(URLQueryItem(name: "tr", value: tracker))
        }

        components.queryItems = queryItems
        return components.string
    }

    private func magnetURIByMergingTrackers(_ raw: String) -> String {
        let sourceTrackers = torrentTrackers
        guard !sourceTrackers.isEmpty,
              var components = URLComponents(string: raw) else {
            return raw
        }

        var queryItems = components.queryItems ?? []
        var existingTrackers = Set(
            queryItems
                .filter { $0.name.lowercased() == "tr" }
                .compactMap(\.value)
                .map(normalizedTracker)
        )

        for tracker in sourceTrackers {
            if existingTrackers.insert(normalizedTracker(tracker)).inserted {
                queryItems.append(URLQueryItem(name: "tr", value: tracker))
            }
        }

        components.queryItems = queryItems
        return components.string ?? raw
    }

    var torrentTrackerCount: Int { torrentTrackers.count }

    private static let fallbackHTTPSSTrackers = [
        "https://tracker.pmman.tech:443/announce",
        "https://tracker.nekomi.cn:443/announce",
        "https://004430.xyz:443/announce",
        "https://tracker.7471.top:443/announce",
        "https://tr.nyacat.pw:443/announce",
        "https://open.ftorrent.com:443/announce",
        "https://tracker.foreverpirates.co:443/announce",
        "https://tracker.bug38.com:443/announce",
        "https://pybittrack.retiolus.net:443/announce",
        "https://t.213891.xyz:443/announce"
    ]

    private static let fallbackUDPTrackers = [
        "udp://tracker.opentrackr.org:1337/announce",
        "udp://open.stealth.si:80/announce",
        "udp://tracker.torrent.eu.org:451/announce",
        "udp://open.demonii.com:1337/announce",
        "udp://exodus.desync.com:6969/announce",
        "udp://tracker.qu.ax:6969/announce",
        "udp://tracker2.dler.org:80/announce",
        "udp://tracker.dler.org:6969/announce"
    ]

    private var torrentTrackers: [String] {
        let sourceTrackers = (sources ?? []).compactMap { source -> String? in
            let value = source.trimmingCharacters(in: .whitespacesAndNewlines)
            guard value.lowercased().hasPrefix("tracker:") else { return nil }

            let tracker = String(value.dropFirst("tracker:".count))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let lowered = tracker.lowercased()

            guard lowered.hasPrefix("http://")
                    || lowered.hasPrefix("https://")
                    || lowered.hasPrefix("udp://") else { return nil }
            return tracker
        }

        // Prefer HTTPS on iOS. UDP/DHT may be blocked by the current network and
        // cleartext HTTP can be rejected by App Transport Security.
        let ordered = sourceTrackers.filter { $0.lowercased().hasPrefix("https://") }
            + Self.fallbackHTTPSSTrackers
            + sourceTrackers.filter { !$0.lowercased().hasPrefix("https://") }
            + Self.fallbackUDPTrackers

        var seen = Set<String>()
        return ordered.filter { seen.insert(normalizedTracker($0)).inserted }
    }

    private func normalizedTracker(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private var sourceText: String { [name, title].compactMap { $0 }.joined(separator: " ") }

    var quality: String {
        let text = sourceText.lowercased()
        if text.contains("2160p") || text.contains("4k") { return "4K" }
        if text.contains("1080p") { return "1080p" }
        if text.contains("720p") { return "720p" }
        if text.contains("480p") { return "480p" }
        return "Auto"
    }

    var codec: String? {
        let text = sourceText.lowercased()
        if text.contains("av1") { return "AV1" }
        if text.contains("hevc") || text.contains("h265") || text.contains("x265") { return "HEVC" }
        if text.contains("h264") || text.contains("x264") { return "H.264" }
        return nil
    }

    var dynamicRange: String? {
        let text = sourceText.lowercased()
        if text.contains("dolby vision") || text.contains(" dv ") { return "Dolby Vision" }
        if text.contains("hdr10+") { return "HDR10+" }
        if text.contains("hdr") { return "HDR" }
        return nil
    }

    var fileSize: String? {
        let pattern = #"(?i)(\d+(?:\.\d+)?)\s*(GB|MB)"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: sourceText, range: NSRange(sourceText.startIndex..., in: sourceText)),
              let valueRange = Range(match.range(at: 1), in: sourceText),
              let unitRange = Range(match.range(at: 2), in: sourceText) else { return nil }
        return "\(sourceText[valueRange]) \(sourceText[unitRange].uppercased())"
    }

    var sourceSummary: String {
        [quality, codec, dynamicRange, fileSize].compactMap { $0 }.joined(separator: " · ")
    }

    var qualityRank: Int {
        switch quality {
        case "4K": return 4
        case "1080p": return 3
        case "720p": return 2
        case "480p": return 1
        default: return 0
        }
    }
}
