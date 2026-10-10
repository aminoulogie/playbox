import SwiftUI

struct AddonsView: View {
    @EnvironmentObject private var store: AddonStore
    @State private var addonURL = ""

    var body: some View {
        List {
            Section("Install add-on") {
                TextField("https://example.com/addon", text: $addonURL)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)

                Button("Install") {
                    Task { await store.install(addonURL) }
                }
                .disabled(addonURL.trimmingCharacters(in: .whitespaces).isEmpty)

                if let error = store.errorMessage {
                    Text(error).foregroundStyle(.red)
                }
            }

            Section("Installed") {
                if store.addons.isEmpty {
                    Text("No add-ons installed.").foregroundStyle(.secondary)
                }

                ForEach(store.addons) { addon in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(addon.manifest.name).font(.headline)
                        Text(addon.baseURL.absoluteString)
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .onDelete(perform: store.remove)
            }
        }
        .navigationTitle("Add-ons")
    }
}
