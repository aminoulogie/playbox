import Foundation

struct AddonManifest: Codable, Identifiable {
    let id: String
    let version: String?
    let name: String
    let description: String?
    let resources: [String]?
    let types: [String]?
    let catalogs: [AddonCatalog]?
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
}

struct CatalogResponse: Codable { let metas: [MetaPreview] }
struct StreamResponse: Codable { let streams: [AddonStream] }

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
        guard let url, let value = URL(string: url),
              ["http", "https"].contains(value.scheme?.lowercased() ?? "") else { return nil }
        return value
    }

    var isTorrent: Bool {
        infoHash != nil || url?.lowercased().hasPrefix("magnet:") == true
    }
}
