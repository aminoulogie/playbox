import SwiftUI

private struct CatalogSection: Identifiable {
    let id: String
    let title: String
    let items: [MetaPreview]
}

struct CatalogView: View {
    @EnvironmentObject private var store: AddonStore
    @State private var sections: [CatalogSection] = []
    @State private var loading = false
    @State private var errorMessage: String?
    @State private var searchText = ""

    private let cinemeta = URL(string: "https://v3-cinemeta.strem.io")!

    var body: some View {
        Group {
            if sections.isEmpty && !loading {
                ContentUnavailableView(
                    errorMessage == nil ? "No Titles Found" : "Couldn't Load Discover",
                    systemImage: "film.stack",
                    description: Text(errorMessage ?? "Pull down to refresh.")
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 28) {
                        if searchText.isEmpty, let hero = sections.first?.items.first {
                            NavigationLink(value: hero) {
                                ZStack(alignment: .bottomLeading) {
                                    AsyncImage(url: hero.poster.flatMap(URL.init(string:))) { image in
                                        image.resizable().scaledToFill()
                                    } placeholder: { Rectangle().fill(.gray.opacity(0.2)) }
                                    .frame(height: 330).clipped()

                                    LinearGradient(
                                        colors: [.clear, .black.opacity(0.9)],
                                        startPoint: .center, endPoint: .bottom
                                    )
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(hero.name).font(.largeTitle.bold()).foregroundStyle(.white)
                                        HStack {
                                            if let rating = hero.imdbRating {
                                                Label(rating, systemImage: "star.fill")
                                            }
                                            Text(hero.type.capitalized)
                                        }
                                        .font(.subheadline).foregroundStyle(.white.opacity(0.9))
                                        Label("View details", systemImage: "play.circle.fill")
                                            .font(.headline).foregroundStyle(.white)
                                    }.padding(20)
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 18))
                                .padding(.horizontal)
                            }
                            .buttonStyle(.plain)
                        }

                        ForEach(sections) { section in
                            VStack(alignment: .leading, spacing: 12) {
                                Text(section.title).font(.title2.bold()).padding(.horizontal)
                                ScrollView(.horizontal, showsIndicators: false) {
                                    LazyHStack(alignment: .top, spacing: 12) {
                                        ForEach(section.items) { item in
                                            NavigationLink(value: item) {
                                                VStack(alignment: .leading, spacing: 6) {
                                                    ZStack(alignment: .topTrailing) {
                                                        AsyncImage(url: item.poster.flatMap(URL.init(string:))) { image in
                                                            image.resizable().scaledToFill()
                                                        } placeholder: {
                                                            Rectangle().fill(.gray.opacity(0.2))
                                                                .overlay { Image(systemName: "film").foregroundStyle(.secondary) }
                                                        }
                                                        .frame(width: 135, height: 200).clipped()
                                                        .clipShape(RoundedRectangle(cornerRadius: 11))
                                                        if let rating = item.imdbRating {
                                                            Text("★ \(rating)")
                                                                .font(.caption2.bold()).padding(5)
                                                                .background(.black.opacity(0.75), in: Capsule())
                                                                .foregroundStyle(.white).padding(6)
                                                        }
                                                    }
                                                    Text(item.name).font(.caption.weight(.semibold)).lineLimit(1)
                                                    Text(item.type.capitalized).font(.caption2).foregroundStyle(.secondary)
                                                }
                                                .frame(width: 135, alignment: .leading)
                                            }.foregroundStyle(.primary)
                                        }
                                    }.padding(.horizontal)
                                }
                            }
                        }
                    }.padding(.vertical)
                }.refreshable { await load() }
            }
        }
        .overlay { if loading && sections.isEmpty { ProgressView() } }
        .navigationTitle("Playbox")
        .searchable(text: $searchText, prompt: "Movies and series")
        .onSubmit(of: .search) { Task { await search() } }
        .onChange(of: searchText) { _, value in
            if value.isEmpty { Task { await load() } }
        }
        .navigationDestination(for: MetaPreview.self) { DetailView(item: $0) }
        .task { await load() }
    }

    private func search() async {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        loading = true
        defer { loading = false }
        async let movies = try? AddonClient().search(baseURL: cinemeta, type: "movie", query: query)
        async let series = try? AddonClient().search(baseURL: cinemeta, type: "series", query: query)
        let combined = (await movies ?? []) + (await series ?? [])
        sections = combined.isEmpty ? [] : [CatalogSection(id: "search", title: "Search Results", items: combined)]
        errorMessage = combined.isEmpty ? "No matching movies or series were found." : nil
    }

    private func load() async {
        loading = true
        defer { loading = false }
        var sources: [(String, URL, String, String)] = [
            ("Popular Movies", cinemeta, "movie", "top"),
            ("Popular Series", cinemeta, "series", "top"),
            ("Top Rated Movies", cinemeta, "movie", "imdbRating"),
            ("Top Rated Series", cinemeta, "series", "imdbRating")
        ]
        for addon in store.addons where addon.manifest.id != "com.linvo.cinemeta" {
            for catalog in addon.manifest.catalogs ?? [] {
                sources.append((catalog.name ?? addon.manifest.name, addon.baseURL, catalog.type, catalog.id))
            }
        }
        var results: [CatalogSection] = []
        await withTaskGroup(of: (Int, [MetaPreview]?).self) { group in
            for (index, source) in sources.enumerated() {
                group.addTask {
                    let items = try? await AddonClient().catalog(baseURL: source.1, type: source.2, id: source.3)
                    return (index, items)
                }
            }
            for await (index, items) in group where items?.isEmpty == false {
                results.append(CatalogSection(id: String(index), title: sources[index].0, items: items!))
            }
        }
        sections = results.sorted { (Int($0.id) ?? 0) < (Int($1.id) ?? 0) }
        errorMessage = sections.isEmpty ? "No catalog data was returned. Check your connection." : nil
    }
}
