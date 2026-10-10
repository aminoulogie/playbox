import Foundation

@MainActor
final class AddonStore: ObservableObject {
    struct InstalledAddon: Identifiable {
        let id = UUID()
        let baseURL: URL
        let manifest: AddonManifest
    }

    @Published private(set) var addons: [InstalledAddon] = []
    @Published var errorMessage: String?
    private let client = AddonClient()

    func install(_ input: String) async {
        var value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasSuffix("/manifest.json") {
            value.removeLast("/manifest.json".count)
        }

        guard let url = URL(string: value),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            errorMessage = AddonError.invalidURL.localizedDescription
            return
        }

        do {
            let manifest = try await client.manifest(baseURL: url)
            addons.removeAll { $0.manifest.id == manifest.id }
            addons.append(.init(baseURL: url, manifest: manifest))
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func remove(at offsets: IndexSet) {
        addons.remove(atOffsets: offsets)
    }
}
