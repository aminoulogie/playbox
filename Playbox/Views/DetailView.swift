import SwiftUI

struct DetailView: View {
    @EnvironmentObject private var store: AddonStore
    @EnvironmentObject private var library: LibraryStore
    @EnvironmentObject private var downloads: DownloadManager
    let item: MetaPreview

    @State private var metadata: MetaPreview?
    @State private var streams: [AddonStream] = []
    @State private var subtitles: [AddonSubtitle] = []
    @State private var selectedSubtitle: AddonSubtitle?
    @State private var playerURL: PlayableURL?
    @State private var selectedSeason = 1
    @State private var showUnsupported = false
    @State private var selectedEpisodeID: String?
    @State private var isLoadingSources = false
    @State private var torrentEngine: TorrentEngine?
    @State private var torrentState: TorrentEngine.EngineState = .idle
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
                .onChange(of: selectedSeason) {
                    selectedEpisodeID = nil
                    streams = []
                    subtitles = []
                }

                ForEach(episodes(in: videos)) { episode in
                    Button {
                        selectedEpisodeID = episode.id
                        Task { await loadMedia(id: episode.id) }
                    } label: {
                        HStack(spacing: 12) {
                            AsyncImage(url: episode.thumbnail.flatMap(URL.init(string:))) { image in
                                image.resizable().scaledToFill()
                            } placeholder: {
                                ZStack { Rectangle().fill(.gray.opacity(0.18)); Image(systemName: "tv") }
                            }
                            .frame(width: 120, height: 68).clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 8))

                            VStack(alignment: .leading, spacing: 4) {
                                Text("E\(episode.episode ?? 0) · \(episode.title ?? "Episode")")
                                    .font(.headline).lineLimit(2)
                                HStack(spacing: 8) {
                                    if let runtime = episode.runtime { Label(runtime, systemImage: "clock") }
                                    if let released = episode.released { Text(String(released.prefix(10))) }
                                }
                                .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            if selectedEpisodeID == episode.id {
                                if isLoadingSources { ProgressView() } else { Image(systemName: "checkmark.circle.fill") }
                            }
                        }
                        .padding(.vertical, 4)
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

    private var playableStreams: [AddonStream] { streams.filter { $0.playableURL != nil } }
    private var torrentStreams: [AddonStream] { streams.filter { $0.isTorrent } }
    private var unsupportedStreams: [AddonStream] { streams.filter { $0.playableURL == nil && !$0.isTorrent } }

    private var sources: some View {
        Section(selectedEpisodeID == nil && item.type == "series" ? "Sources" : "Play") {
            if item.type == "series" && selectedEpisodeID == nil {
                ContentUnavailableView("Choose an episode", systemImage: "rectangle.stack", description: Text("Select an episode above to find its available sources."))
            } else if isLoadingSources {
                HStack { Spacer(); ProgressView("Finding sources…"); Spacer() }
            } else if case .downloading = torrentState {
                HStack { Spacer(); ProgressView("Downloading torrent…"); Spacer() }
            } else if case .resolving = torrentState {
                HStack { Spacer(); ProgressView("Resolving magnet link…"); Spacer() }
            } else if case .failed(let error) = torrentState {
                ContentUnavailableView("Torrent failed", systemImage: "exclamationmark.triangle", description: Text(error))
            } else if streams.isEmpty {
                ContentUnavailableView("No sources", systemImage: "play.slash", description: Text("No installed add-on returned a source for this title."))
            } else if playableStreams.isEmpty && torrentStreams.isEmpty {
                ContentUnavailableView("No playable source available", systemImage: "play.slash", description: Text("\(unsupportedStreams.count) source(s) were found, but they are not directly playable."))
            }

            ForEach(playableStreams) { stream in
                HStack(spacing: 12) {
                    Button {
                        if let url = stream.playableURL { playerURL = PlayableURL(url: url) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(stream.quality).font(.headline)
                                Text(stream.title ?? stream.name ?? "Direct stream").font(.caption).lineLimit(2)
                                Text(stream.sourceSummary).font(.caption2).foregroundStyle(.secondary)
                                downloadStatus(for: stream)
                            }
                            Spacer()
                            Image(systemName: "play.circle.fill").font(.title2)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)

                    downloadButton(for: stream)
                }
            }

            ForEach(torrentStreams) { stream in
                Button {
                    Task { await playTorrent(stream) }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(stream.quality).font(.headline)
                            Text(stream.title ?? stream.name ?? "Torrent source").font(.caption).lineLimit(2)
                            Text(stream.sourceSummary).font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "play.circle.fill").font(.title2)
                    }
                }
            }

            if !(item.type == "series" && selectedEpisodeID == nil) && !unsupportedStreams.isEmpty {
                DisclosureGroup("Unavailable sources (\(unsupportedStreams.count))", isExpanded: $showUnsupported) {
                    ForEach(unsupportedStreams) { stream in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(stream.title ?? stream.name ?? "Source").font(.caption).lineLimit(2)
                            Text(stream.playbackStatus).font(.caption2).foregroundStyle(.secondary)
                        }.padding(.vertical, 3)
                    }
                }
            }
        }
    }

    // MARK: - Downloads

    @ViewBuilder private func downloadButton(for stream: AddonStream) -> some View {
        if let url = stream.playableURL {
            let job = downloads.jobs[stream.id]

            switch job?.state {
            case .some(.downloading):
                Button {
                    downloads.cancel(id: stream.id)
                } label: {
                    ZStack {
                        ProgressView(value: job?.progress ?? 0)
                            .progressViewStyle(.circular)
                        Image(systemName: "stop.fill")
                            .font(.system(size: 8))
                    }
                    .frame(width: 30, height: 30)
                }
                .buttonStyle(.borderless)

            case .some(.finished(_)):
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(.green)

            case .some(.failed(_)):
                Button {
                    downloads.retry(id: stream.id, url: url, name: downloadName(for: stream))
                } label: {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .font(.title2)
                        .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)

            case .none:
                Button {
                    downloads.start(id: stream.id, url: url, name: downloadName(for: stream))
                } label: {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.title2)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    @ViewBuilder private func downloadStatus(for stream: AddonStream) -> some View {
        switch downloads.jobs[stream.id]?.state {
        case .some(.downloading):
            let percent = Int((downloads.jobs[stream.id]?.progress ?? 0) * 100)
            Text("Downloading… \(percent)%")
                .font(.caption2)
                .foregroundStyle(.blue)

        case .some(.finished(_)):
            Text("Saved to Files › Playbox › Downloads")
                .font(.caption2)
                .foregroundStyle(.green)

        case .some(.failed(let message)):
            Text("Download failed: \(message)")
                .font(.caption2)
                .foregroundStyle(.red)
                .lineLimit(2)

        case .none:
            EmptyView()
        }
    }

    private func downloadName(for stream: AddonStream) -> String {
        var parts = [metadata?.name ?? item.name]

        if let id = selectedEpisodeID,
           let episode = metadata?.videos?.first(where: { $0.id == id }),
           let season = episode.season,
           let number = episode.episode {
            parts.append("S\(season)E\(number)")
        }

        parts.append(stream.quality)
        return parts.joined(separator: " ")
    }

    // MARK: - Loading

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
            selectedEpisodeID = nil
            streams = []
            subtitles = []
            return
        }
        await loadMedia(id: item.id)
    }

    private func loadMedia(id: String) async {
        isLoadingSources = true
        streams = []
        subtitles = []
        defer { isLoadingSources = false }
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
            if $0.isTorrent != $1.isTorrent { return !$0.isTorrent }
            return $0.qualityRank > $1.qualityRank
        }
        subtitles = Array(Set(foundSubtitles)).sorted { ($0.lang ?? "") < ($1.lang ?? "") }
    }

    private func playTorrent(_ stream: AddonStream) async {
        let engine = TorrentEngine()
        torrentEngine = engine
        torrentState = .idle

        let magnetURL: String
        if let url = stream.url, !url.isEmpty {
            magnetURL = url
        } else if let hash = stream.infoHash {
            magnetURL = "magnet:?xt=urn:btih:\(hash)"
        } else {
            torrentState = .failed("No magnet URL was supplied for this torrent source")
            return
        }

        await engine.play(magnetLink: magnetURL)
        let nextState = await engine.state
        torrentState = nextState

        if case .ready(let url) = nextState {
            playerURL = PlayableURL(url: url)
        }
    }
}

private struct PlayableURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
