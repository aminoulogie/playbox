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

    var id: String {
        [name, title, url, infoHash, fileIdx.map(String.init)]
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
        if isTorrent { return "Torrent/magnet source · not directly playable" }
        return "Unsupported stream URL"
    }

    var isTorrent: Bool {
        infoHash != nil || url?.lowercased().hasPrefix("magnet:") == true
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
