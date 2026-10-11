import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @AppStorage("playbox.library.posterColumns") private var posterColumns = 4

    private var density: Int {
        min(max(posterColumns, 1), 12)
    }

    private var itemSpacing: CGFloat {
        switch density {
        case 1...2: 14
        case 3...4: 10
        case 5...6: 6
        default: 4
        }
    }

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(minimum: 0), spacing: itemSpacing),
            count: density
        )
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 24) {
                if !library.recent.isEmpty {
                    sectionHeader("Continue Watching")

                    LazyVGrid(columns: columns, spacing: itemSpacing + 4) {
                        ForEach(library.recent) { entry in
                            NavigationLink(value: entry.item) {
                                posterCard(entry, showsProgress: true)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .id("recent-\(density)")
                }

                sectionHeader("My Library")

                if library.saved.isEmpty {
                    ContentUnavailableView(
                        "Your library is empty",
                        systemImage: "books.vertical",
                        description: Text("Save a movie or series from its details page.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
                } else {
                    LazyVGrid(columns: columns, spacing: itemSpacing + 4) {
                        ForEach(library.saved) { entry in
                            NavigationLink(value: entry.item) {
                                posterCard(entry, showsProgress: false)
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button(role: .destructive) {
                                    library.removeSaved(id: entry.id)
                                } label: {
                                    Label("Remove from Library", systemImage: "trash")
                                }
                            }
                        }
                    }
                    .id("saved-\(density)")
                }
            }
            .padding(.horizontal, density >= 7 ? 6 : 12)
            .padding(.vertical, 12)
        }
        .navigationTitle("Library")
        .navigationDestination(for: MetaPreview.self) { DetailView(item: $0) }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.title3.bold())
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func posterCard(_ entry: LibraryStore.Entry, showsProgress: Bool) -> some View {
        VStack(alignment: .leading, spacing: density >= 6 ? 3 : 7) {
            AsyncImage(url: entry.poster.flatMap(URL.init(string:))) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Rectangle().fill(.gray.opacity(0.2))
                    .overlay {
                        Image(systemName: "film")
                            .font(density >= 7 ? .caption2 : .body)
                            .foregroundStyle(.secondary)
                    }
            }
            .aspectRatio(2.0 / 3.0, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: density >= 7 ? 4 : 8))

            if density <= 8 {
                Text(entry.name)
                    .font(density >= 6 ? .system(size: 9.5, weight: .semibold) : .caption)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
            }

            if showsProgress {
                ProgressView(value: entry.progress)
                    .controlSize(.mini)
            }
        }
        .contentShape(Rectangle())
    }
}
