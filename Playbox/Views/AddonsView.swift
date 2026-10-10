import SwiftUI

struct AddonsView: View {
    @EnvironmentObject private var store: AddonStore
    @State private var addonURL = ""
    @State private var search = ""

    private var featured: [AddonStore.FeaturedAddon] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return AddonStore.featured }
        return AddonStore.featured.filter {
            $0.name.localizedCaseInsensitiveContains(query) ||
            $0.summary.localizedCaseInsensitiveContains(query) ||
            $0.category.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        List {
            Section("Featured Add-on Store") {
                TextField("Search add-ons", text: $search)
                    .textInputAutocapitalization(.never)
                ForEach(featured) { addon in
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: icon(for: addon.category))
                            .font(.title2).frame(width: 32)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(addon.name).font(.headline)
                            Text(addon.category).font(.caption).foregroundStyle(.secondary)
                            Text(addon.summary).font(.caption).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 4)
                        Button(store.isInstalled(addon) ? "Installed" : "Install") {
                            Task { await store.install(addon.manifestURL) }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(store.isInstalled(addon) || store.installingURL != nil)
                    }
                    .padding(.vertical, 5)
                }
            }

            Section("Install from URL") {
                TextField("https://example.com/manifest.json", text: $addonURL)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    .autocorrectionDisabled()
                Button("Install URL") {
                    Task { await store.install(addonURL) }
                }
                .disabled(addonURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if let error = store.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }

            Section("Installed") {
                if store.addons.isEmpty {
                    Text("No add-ons installed yet.").foregroundStyle(.secondary)
                }
                ForEach(store.addons) { addon in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(addon.manifest.name).font(.headline)
                        Text(addon.baseURL.absoluteString).font(.caption2).foregroundStyle(.secondary)
                    }
                }
                .onDelete(perform: store.remove)
            }
        }
        .navigationTitle("Add-on Store")
    }

    private func icon(for category: String) -> String {
        switch category {
        case "Catalogs": return "film.stack"
        case "Subtitles": return "captions.bubble"
        case "Discovery": return "magnifyingglass"
        default: return "square.stack.3d.up"
        }
    }
}
