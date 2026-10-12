import Foundation

@MainActor
final class AddonStore: ObservableObject {
    struct InstalledAddon: Identifiable, Codable {
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
        .init(id: "torrentio", name: "Torrentio", summary: "Community source index with direct and torrent sources.", category: "Community", manifestURL: "https://torrentio.strem.fun/manifest.json")
    ]

    @Published private(set) var addons: [InstalledAddon] = []
    @Published var errorMessage: String?
    @Published var installingURL: String?
    private let client = AddonClient()
    private let storageKey = "playbox.addons.urls"
    private let manifestCacheKey = "playbox.addons.manifestCache"

    init() {
        // Show the last known add-ons immediately; refresh them in the background.
        if let data = UserDefaults.standard.data(forKey: manifestCacheKey),
           let cached = try? JSONDecoder().decode([InstalledAddon].self, from: data) {
            addons = cached
        }
        Task { await refreshInstalled() }
    }

    /// Re-fetches every manifest concurrently, keeping the stored order.
    private func refreshInstalled() async {
        let urls = UserDefaults.standard.stringArray(forKey: storageKey) ?? []
        guard !urls.isEmpty else {
            await install(Self.featured[0].manifestURL)
            return
        }
        let client = client
        let bases = urls.compactMap { URL(string: baseURLString($0)) }
        let fetched = await withTaskGroup(of: (Int, AddonManifest?).self) { group in
            for (index, base) in bases.enumerated() {
                group.addTask { (index, try? await client.manifest(baseURL: base)) }
            }
            var results: [Int: AddonManifest] = [:]
            for await (index, manifest) in group {
                if let manifest { results[index] = manifest }
            }
            return results
        }
        var refreshed: [InstalledAddon] = []
        for (index, base) in bases.enumerated() {
            if let manifest = fetched[index] {
                refreshed.append(.init(baseURL: base, manifest: manifest))
            } else if let cached = addons.first(where: { $0.baseURL == base }) {
                refreshed.append(cached)
            }
        }
        // The user installed or removed an add-on while this was running.
        guard urls == (UserDefaults.standard.stringArray(forKey: storageKey) ?? []) else { return }
        var seen = Set<String>()
        refreshed = refreshed.filter { seen.insert($0.manifest.id).inserted }
        addons = refreshed
        persist()
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
        if let data = try? JSONEncoder().encode(addons) {
            UserDefaults.standard.set(data, forKey: manifestCacheKey)
        }
    }

    private func baseURLString(_ input: String) -> String {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasSuffix("/manifest.json") { value.removeLast("/manifest.json".count) }
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }
}
