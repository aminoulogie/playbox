import Foundation

enum MagnetError: LocalizedError {
    case invalidURL, missingInfoHash, invalidInfoHash
    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid magnet link."
        case .missingInfoHash: return "The magnet link has no BitTorrent info hash."
        case .invalidInfoHash: return "The BitTorrent info hash is not a valid 40-character SHA-1 hash."
        }
    }
}

struct MagnetLink: Hashable, Sendable {
    let infoHash: String
    let displayName: String?
    let trackers: [URL]
    let webSeeds: [URL]

    init(_ raw: String) throws {
        guard let components = URLComponents(string: raw),
              components.scheme?.lowercased() == "magnet" else { throw MagnetError.invalidURL }
        let items = components.queryItems ?? []
        guard let exact = items.first(where: { $0.name == "xt" })?.value,
              exact.lowercased().hasPrefix("urn:btih:") else { throw MagnetError.missingInfoHash }
        let hash = String(exact.dropFirst("urn:btih:".count)).lowercased()
        guard hash.count == 40, hash.allSatisfy({ $0.isHexDigit }) else { throw MagnetError.invalidInfoHash }
        infoHash = hash
        displayName = items.first(where: { $0.name == "dn" })?.value
        trackers = items.filter { $0.name == "tr" }.compactMap { $0.value }.compactMap(URL.init(string:))
        webSeeds = items.filter { $0.name == "ws" }.compactMap { $0.value }.compactMap(URL.init(string:))
    }
}
