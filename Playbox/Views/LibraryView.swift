import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore

    var body: some View {
        List {
            if !library.recent.isEmpty {
                Section("Continue Watching") {
                    ForEach(library.recent) { entry in
                        NavigationLink(value: entry.item) {
                            HStack(spacing: 12) {
                                poster(entry.poster)
                                VStack(alignment: .leading, spacing: 7) {
                                    Text(entry.name).font(.headline)
                                    Text(entry.type.capitalized).font(.caption).foregroundStyle(.secondary)
                                    ProgressView(value: entry.progress)
                                }
                            }
                        }
                    }
                }
            }
            Section("My Library") {
                if library.saved.isEmpty {
                    Text("Save a movie or series from its details page.").foregroundStyle(.secondary)
                }
                ForEach(library.saved) { entry in
                    NavigationLink(value: entry.item) {
                        HStack(spacing: 12) { poster(entry.poster); Text(entry.name).font(.headline) }
                    }
                }.onDelete(perform: library.removeSaved)
            }
        }
        .navigationTitle("Library")
        .navigationDestination(for: MetaPreview.self) { DetailView(item: $0) }
    }

    private func poster(_ value: String?) -> some View {
        AsyncImage(url: value.flatMap(URL.init(string:))) { image in image.resizable().scaledToFill() }
        placeholder: { Rectangle().fill(.gray.opacity(0.2)) }
            .frame(width: 52, height: 76).clipped().clipShape(RoundedRectangle(cornerRadius: 7))
    }
}
