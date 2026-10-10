import Foundation

@MainActor
final class AddonStore: ObservableObject {
    struct InstalledAddon: Identifiable {
        var id: String { manifest.id }
        let baseURL: URL
        let manifest: AddonManifest
    }

    struct FeaturedAddon: Identifiable {
        let id: String
        let name: String
        let summary: String
        let category: String
        let manifestURL: String
    }

    static let featured: [FeaturedAddon] = [
        .init(id: "cinemeta", name: "Cinemeta", summary: "Movie and series catalogs, metadata and ratings", category: "Catalogs", manifestURL: "https://v3-cinemeta.strem.io/manifest.json"),
        .init(id: "opensubtitles", name: "OpenSubtitles v3", summary: "Subtitles in multiple languages", category: "Subtitles", manifestURL: "https://opensubtitles-v3.strem.io/manifest.json"),
        .init(id: "watchhub", name: "WatchHub", summary: "Find official streaming availability", category: "Discovery", manifestURL: "https://watchhub.strem.io/manifest.json"),
        .init(id: "torrentio", name: "Torrentio", summary: "Community source index. Torrent-only sources are not playable in Playbox.", category: "Community", manifestURL: "https://torrentio.strem.fun/manifest.json")
    ]

    @Published private(set) var addons: [InstalledAddon] = []
    @Published var errorMessage: String?
    @Published var installingURL: String?
    private let client = AddonClient()
    private let storageKey = "playbox.addons.urls"

    init() {
        Task {
            let urls = UserDefaults.standard.stringArray(forKey: storageKey) ?? []
            if urls.isEmpty {
                await install(Self.featured[0].manifestURL)
            } else {
                for url in urls { await install(url) }
            }
        }
    }

    func isInstalled(_ featured: FeaturedAddon) -> Bool {
        addons.contains { $0.baseURL.absoluteString == baseURLString(featured.manifestURL) }
    }

    func install(_ input: String) async {
        let normalized = baseURLString(input)
        guard let url = URL(string: normalized),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            errorMessage = AddonError.invalidURL.localizedDescription
            return
        }
        if addons.contains(where: { $0.baseURL == url }) { return }
        installingURL = normalized
        defer { installingURL = nil }
        do {
            let manifest = try await client.manifest(baseURL: url)
            addons.removeAll { $0.manifest.id == manifest.id }
            addons.append(.init(baseURL: url, manifest: manifest))
            errorMessage = nil
            persist()
        } catch {
            errorMessage = "\(url.host ?? "Add-on"): \(error.localizedDescription)"
        }
    }

    func remove(at offsets: IndexSet) {
        addons.remove(atOffsets: offsets)
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(addons.map { $0.baseURL.absoluteString }, forKey: storageKey)
    }

    private func baseURLString(_ input: String) -> String {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasSuffix("/manifest.json") { value.removeLast("/manifest.json".count) }
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }
}
