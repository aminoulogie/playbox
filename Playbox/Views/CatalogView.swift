import SwiftUI

struct CatalogView: View {
    @EnvironmentObject private var store: AddonStore
    @State private var items: [MetaPreview] = []
    @State private var loading = false
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if store.addons.isEmpty {
                ContentUnavailableView(
                    "No Add-ons",
                    systemImage: "puzzlepiece.extension",
                    description: Text("Install a compatible add-on to load a catalog.")
                )
            } else {
                List(items) { item in
                    NavigationLink(value: item) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.name).font(.headline)
                            Text(item.type.capitalized)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                .navigationDestination(for: MetaPreview.self) {
                    DetailView(item: $0)
                }
                .overlay {
                    if loading { ProgressView() }
                    else if let errorMessage {
                        ContentUnavailableView(
                            "Couldn’t Load Catalog",
                            systemImage: "exclamationmark.triangle",
                            description: Text(errorMessage)
                        )
                    }
                }
            }
        }
        .navigationTitle("Playbox")
        .task(id: store.addons.count) { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        guard let addon = store.addons.first,
              let catalog = addon.manifest.catalogs?.first else {
            items = []
            return
        }

        loading = true
        defer { loading = false }

        do {
            items = try await AddonClient().catalog(
                baseURL: addon.baseURL,
                type: catalog.type,
                id: catalog.id
            )
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
