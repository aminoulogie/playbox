import SwiftUI

struct DetailView: View {
    @EnvironmentObject private var store: AddonStore
    @EnvironmentObject private var library: LibraryStore
    let item: MetaPreview

    @State private var metadata: MetaPreview?
    @State private var streams: [AddonStream] = []
    @State private var subtitles: [AddonSubtitle] = []
    @State private var selectedSubtitle: AddonSubtitle?
    @State private var playerURL: PlayableURL?
    @State private var selectedSeason = 1
    private let cinemeta = URL(string: "https://v3-cinemeta.strem.io")!

    var body: some View {
        List {
            header
            if let description = metadata?.description ?? item.description {
                Section("About") { Text(description) }
            }
            episodes
            subtitlePicker
            sources
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { library.toggle(metadata ?? item) } label: {
                    Image(systemName: library.contains(metadata ?? item) ? "bookmark.fill" : "bookmark")
                }
            }
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadDetails() }
        .sheet(item: $playerURL) { value in
            TrackedPlayerView(url: value.url, item: metadata ?? item)
        }
    }

    private var header: some View {
        Section {
            HStack(alignment: .top, spacing: 16) {
                AsyncImage(url: posterURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: { Rectangle().fill(.gray.opacity(0.2)) }
                .frame(width: 110, height: 165).clipped()
                .clipShape(RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 8) {
                    Text(metadata?.name ?? item.name).font(.title2.bold())
                    if let rating = metadata?.imdbRating ?? item.imdbRating {
                        Label("\(rating)/10 IMDb", systemImage: "star.fill").font(.subheadline)
                    }
                    if let release = metadata?.releaseInfo ?? item.releaseInfo {
                        Text(release).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var posterURL: URL? {
        guard let value = metadata?.poster ?? item.poster else { return nil }
        return URL(string: value)
    }

    @ViewBuilder private var episodes: some View {
        if item.type == "series", let videos = metadata?.videos, !videos.isEmpty {
            Section("Episodes") {
                Picker("Season", selection: $selectedSeason) {
                    ForEach(seasons(in: videos), id: \.self) { season in Text("Season \(season)").tag(season) }
                }
                ForEach(episodes(in: videos)) { episode in
                    Button {
                        Task { await loadMedia(id: episode.id) }
                    } label: {
                        Text("E\(episode.episode ?? 0) · \(episode.title ?? "Episode")")
                    }
                }
            }
        }
    }

    @ViewBuilder private var subtitlePicker: some View {
        if !subtitles.isEmpty {
            Section("CC / Subtitles") {
                Picker("Subtitle", selection: $selectedSubtitle) {
                    Text("Off").tag(nil as AddonSubtitle?)
                    ForEach(subtitles, id: \.stableID) { subtitle in
                        Text(subtitle.lang?.uppercased() ?? "CC").tag(subtitle as AddonSubtitle?)
                    }
                }
            }
        }
    }

    private var sources: some View {
        Section("Play") {
            if streams.isEmpty { Text("No playable sources returned.").foregroundStyle(.secondary) }
            ForEach(streams) { stream in
                Button {
                    if let url = stream.playableURL { playerURL = PlayableURL(url: url) }
                } label: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(stream.quality).font(.headline)
                        Text(stream.title ?? stream.name ?? "Source").font(.caption).lineLimit(2)
                        Text(stream.sourceSummary).font(.caption2).foregroundStyle(.secondary)
                        Label(stream.playbackStatus, systemImage: stream.playableURL == nil ? "exclamationmark.circle" : "play.circle.fill")
                            .font(.caption2).foregroundStyle(stream.playableURL == nil ? .secondary : .primary)
                    }
                }.disabled(stream.playableURL == nil)
            }
        }
    }

    private func seasons(in videos: [MetaVideo]) -> [Int] {
        Array(Set(videos.compactMap(\.season))).sorted()
    }

    private func episodes(in videos: [MetaVideo]) -> [MetaVideo] {
        videos.filter { $0.season == selectedSeason }.sorted { ($0.episode ?? 0) < ($1.episode ?? 0) }
    }

    private func loadDetails() async {
        metadata = try? await AddonClient().meta(baseURL: cinemeta, type: item.type, id: item.id)
        if item.type == "series", let videos = metadata?.videos, let firstSeason = seasons(in: videos).first {
            selectedSeason = firstSeason
            if let firstEpisode = episodes(in: videos).first { await loadMedia(id: firstEpisode.id); return }
        }
        await loadMedia(id: item.id)
    }

    private func loadMedia(id: String) async {
        var foundStreams: [AddonStream] = []
        var foundSubtitles: [AddonSubtitle] = []
        await withTaskGroup(of: ([AddonStream], [AddonSubtitle]).self) { group in
            for addon in store.addons {
                group.addTask {
                    async let s = try? AddonClient().streams(baseURL: addon.baseURL, type: item.type, id: id)
                    async let c = try? AddonClient().subtitles(baseURL: addon.baseURL, type: item.type, id: id)
                    return (await s ?? [], await c ?? [])
                }
            }
            for await result in group {
                foundStreams += result.0
                foundSubtitles += result.1
            }
        }
        streams = Array(Set(foundStreams)).sorted {
            if ($0.playableURL != nil) != ($1.playableURL != nil) { return $0.playableURL != nil }
            return $0.qualityRank > $1.qualityRank
        }
        subtitles = Array(Set(foundSubtitles)).sorted { ($0.lang ?? "") < ($1.lang ?? "") }
    }
}

private struct PlayableURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
