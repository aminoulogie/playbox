import SwiftUI

struct LibraryView: View {
    @EnvironmentObject private var library: LibraryStore
    @AppStorage("playbox.library.posterColumns") private var posterColumns = 4
    @AppStorage("playbox.library.posterSizingMode") private var posterSizingMode = "columns"
    @AppStorage("playbox.library.posterWidth") private var posterWidth = 135.0

    var body: some View {
        GeometryReader { proxy in
            let layout = PosterLayout(
                availableWidth: proxy.size.width,
                columns: posterColumns,
                sizingMode: posterSizingMode,
                preferredWidth: posterWidth
            )
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 24) {
                    if !library.recent.isEmpty {
                        sectionHeader("Continue Watching")

                        LazyVGrid(columns: layout.gridColumns, alignment: .center, spacing: layout.spacing + 4) {
                            ForEach(library.recent) { entry in
                                NavigationLink(value: entry.item) {
                                    posterCard(entry, showsProgress: true, layout: layout)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(entry.name)
                            }
                        }
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
                        LazyVGrid(columns: layout.gridColumns, alignment: .center, spacing: layout.spacing + 4) {
                            ForEach(library.saved) { entry in
                                NavigationLink(value: entry.item) {
                                    posterCard(entry, showsProgress: false, layout: layout)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(entry.name)
                                .contextMenu {
                                    Button(role: .destructive) {
                                        library.removeSaved(id: entry.id)
                                    } label: {
                                        Label("Remove from Library", systemImage: "trash")
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, layout.horizontalPadding)
                .padding(.vertical, 12)
            }
        }
        .navigationTitle("Library")
        .navigationDestination(for: MetaPreview.self) { DetailView(item: $0) }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.title3.bold())
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func posterCard(_ entry: LibraryStore.Entry, showsProgress: Bool, layout: PosterLayout) -> some View {
        VStack(alignment: .leading, spacing: layout.compact ? 3 : 7) {
            AsyncImage(url: entry.poster.flatMap(URL.init(string:))) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Rectangle().fill(.gray.opacity(0.2))
                    .overlay {
                        Image(systemName: "film")
                            .font(layout.compact ? .caption2 : .body)
                            .foregroundStyle(.secondary)
                    }
            }
            .frame(width: layout.width, height: layout.height)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: layout.compact ? 4 : 8))

            if layout.showsTitle {
                Text(entry.name)
                    .font(layout.compact ? .system(size: 9.5, weight: .semibold) : .caption)
                    .lineLimit(1)
                    .foregroundStyle(.primary)
            }

            if showsProgress {
                ProgressView(value: entry.progress)
                    .controlSize(.mini)
            }
        }
        .frame(width: layout.width, alignment: .leading)
        .contentShape(Rectangle())
    }
}
