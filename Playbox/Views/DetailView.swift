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
    @State private var torrentPlayerSession: TorrentPlayerSession?
    @State private var selectedSeason = 1
    @State private var showUnsupported = false
    @State private var selectedEpisodeID: String?
    @State private var isLoadingSources = false
    @State private var torrentEngine: TorrentEngine?
    @State private var torrentState: TorrentEngine.EngineState = .idle
    @State private var torrentProgress: Double = 0.0
    @State private var torrentPeerCount = 0
    @State private var torrentDownloadSpeed: Double = 0
    @State private var torrentCacheProgress: Double = 0
    @State private var torrentDiagnosticText = "Discovery starting…"
    @State private var activeTorrentID: String?
    @State private var activeTorrentAction: TorrentAction?
    @State private var torrentOperationID: UUID?
    @State private var torrentTask: Task<Void, Never>?
    @State private var torrentErrors: [String: String] = [:]
    @State private var torrentDownloads: [String: URL] = [:]
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
            TrackedPlayerView(
                url: value.url,
                item: metadata ?? item,
                subtitles: value.subtitles,
                selectedSubtitle: value.selectedSubtitle
            )
        }
        .sheet(item: $torrentPlayerSession, onDismiss: {
            if activeTorrentAction == .play {
                cancelActiveTorrent()
            }
        }) { session in
            TorrentPlaybackView(
                engine: session.engine,
                item: metadata ?? item,
                subtitles: session.subtitles,
                selectedSubtitle: session.selectedSubtitle
            )
        }
        .onDisappear {
            cancelActiveTorrent()
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
                    cancelActiveTorrent()
                    selectedEpisodeID = nil
                    streams = []
                    subtitles = []
                }

                ForEach(episodes(in: videos)) { episode in
                    Button {
                        cancelActiveTorrent()
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
            } else if streams.isEmpty {
                ContentUnavailableView("No sources", systemImage: "play.slash", description: Text("No installed add-on returned a source for this title."))
            } else if playableStreams.isEmpty && torrentStreams.isEmpty {
                ContentUnavailableView("No playable source available", systemImage: "play.slash", description: Text("\(unsupportedStreams.count) source(s) were found, but they are not directly playable."))
            }

            ForEach(playableStreams) { stream in
                HStack(spacing: 12) {
                    Button {
                        if let url = stream.playableURL {
                            playerURL = PlayableURL(
                                url: url,
                                subtitles: subtitles,
                                selectedSubtitle: selectedSubtitle
                            )
                        }
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
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(stream.quality).font(.headline)
                        Text(stream.title ?? stream.name ?? "Torrent source").font(.caption).lineLimit(2)
                        Text(stream.sourceSummary).font(.caption2).foregroundStyle(.secondary)
                        torrentStatus(for: stream)
                    }

                    Spacer()

                    if activeTorrentID == stream.id {
                        Button {
                            cancelActiveTorrent()
                        } label: {
                            Image(systemName: "stop.circle.fill")
                                .font(.title2)
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Stop torrent")
                    } else {
                        Button {
                            startTorrent(stream, action: .play)
                        } label: {
                            Image(systemName: "play.circle.fill")
                                .font(.title2)
                        }
                        .buttonStyle(.borderless)
                        .disabled(activeTorrentID != nil)
                        .accessibilityLabel("Play torrent")

                        if torrentDownloads[stream.id] != nil {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.title2)
                                .foregroundStyle(.green)
                                .accessibilityLabel("Torrent downloaded")
                        } else {
                            Button {
                                startTorrent(stream, action: .download)
                            } label: {
                                Image(systemName: "arrow.down.circle.fill")
                                    .font(.title2)
                            }
                            .buttonStyle(.borderless)
                            .disabled(activeTorrentID != nil)
                            .accessibilityLabel("Download torrent")
                        }
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

    @ViewBuilder private func torrentStatus(for stream: AddonStream) -> some View {
        if activeTorrentID == stream.id {
            switch torrentState {
            case .resolving:
                let peerText = torrentPeerCount == 1 ? "1 peer" : "\(torrentPeerCount) peers"
                Text(
                    activeTorrentAction == .download
                        ? "Finding torrent metadata… \(peerText)"
                        : "Preparing playback… \(peerText)"
                )
                .font(.caption2)
                .foregroundStyle(.blue)

                Text("Magnet trackers: \(stream.torrentTrackerCount) · " + torrentDiagnosticText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)

            case .downloading:
                let percent = Int(torrentProgress * 100)
                let peerText = torrentPeerCount == 1 ? "1 peer" : "\(torrentPeerCount) peers"
                Text(
                    activeTorrentAction == .download
                        ? "Downloading… \(percent)% · \(peerText)"
                        : "Preparing playback… \(percent)% · \(peerText)"
                )
                .font(.caption2)
                .foregroundStyle(.blue)

                Text("Magnet trackers: \(stream.torrentTrackerCount) · " + torrentDiagnosticText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)

            case .failed(let message):
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.red)
                    .lineLimit(3)

                Text("Magnet trackers: \(stream.torrentTrackerCount) · " + torrentDiagnosticText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(4)

            case .ready:
                Text(activeTorrentAction == .download ? "Saving to Files…" : "Opening player…")
                    .font(.caption2)
                    .foregroundStyle(.green)

            case .idle:
                EmptyView()
            }
        } else if torrentDownloads[stream.id] != nil {
            Text("Saved to Files › Playbox › Downloads")
                .font(.caption2)
                .foregroundStyle(.green)
        } else if let message = torrentErrors[stream.id] {
            Text(message)
                .font(.caption2)
                .foregroundStyle(.red)
                .lineLimit(2)
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
        selectedSubtitle = nil
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

    @MainActor
    private func startTorrent(_ stream: AddonStream, action: TorrentAction) {
        guard activeTorrentID == nil else { return }

        guard let magnetURL = stream.torrentMagnetURI else {
            torrentErrors[stream.id] = "No magnet URL or info hash was supplied for this torrent source"
            return
        }

        let operationID = UUID()
        let engine = TorrentEngine()

        torrentErrors[stream.id] = nil
        activeTorrentID = stream.id
        activeTorrentAction = action
        torrentOperationID = operationID
        torrentState = .resolving
        torrentProgress = 0.0
        torrentPeerCount = 0
        torrentDownloadSpeed = 0
        torrentCacheProgress = 0
        torrentDiagnosticText = "Discovery starting…"
        torrentEngine = engine

        if action == .play {
            torrentPlayerSession = TorrentPlayerSession(
                engine: engine,
                subtitles: subtitles,
                selectedSubtitle: selectedSubtitle
            )
        }

        torrentTask = Task { @MainActor in
            await runTorrent(
                stream,
                action: action,
                magnetURL: magnetURL,
                operationID: operationID,
                engine: engine
            )
        }
    }

    @MainActor
    private func runTorrent(
        _ stream: AddonStream,
        action: TorrentAction,
        magnetURL: String,
        operationID: UUID,
        engine: TorrentEngine
    ) async {
        await engine.play(
            magnetLink: magnetURL,
            fileIndex: stream.fileIdx
        ) { state, progress, peers, speed, cacheProgress, diagnostics in
            guard torrentOperationID == operationID else { return }
            torrentState = state
            torrentProgress = progress
            torrentPeerCount = peers
            torrentDownloadSpeed = speed
            torrentCacheProgress = cacheProgress
            torrentDiagnosticText = diagnostics
        }

        guard torrentOperationID == operationID, !Task.isCancelled else { return }

        switch torrentState {
        case .ready(let url):
            if action == .download {
                do {
                    let destination = try saveTorrentDownload(
                        from: url,
                        name: downloadName(for: stream)
                    )
                    torrentDownloads[stream.id] = destination
                } catch {
                    torrentErrors[stream.id] = "Could not save torrent: \(error.localizedDescription)"
                }
            }

        case .failed(let message):
            torrentErrors[stream.id] = message

        default:
            break
        }

        finishTorrentOperation(operationID)
    }

    @MainActor
    private func cancelActiveTorrent() {
        guard activeTorrentID != nil else { return }

        torrentTask?.cancel()
        let engine = torrentEngine

        activeTorrentID = nil
        activeTorrentAction = nil
        torrentOperationID = nil
        torrentTask = nil
        torrentEngine = nil
        torrentState = .idle
        torrentProgress = 0.0
        torrentPeerCount = 0
        torrentDownloadSpeed = 0
        torrentCacheProgress = 0
        torrentDiagnosticText = "Discovery stopped"

        if let engine {
            Task { @MainActor in
                await engine.cancel()
            }
        }
    }

    @MainActor
    private func finishTorrentOperation(_ operationID: UUID) {
        guard torrentOperationID == operationID else { return }

        activeTorrentID = nil
        activeTorrentAction = nil
        torrentOperationID = nil
        torrentTask = nil
        torrentEngine = nil
        torrentState = .idle
        torrentProgress = 0.0
        torrentPeerCount = 0
        torrentDownloadSpeed = 0
        torrentCacheProgress = 0
    }

    private func formatTorrentSpeed(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 0 else { return "0 B/s" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: Int64(bytesPerSecond)) + "/s"
    }

    private func saveTorrentDownload(from source: URL, name: String) throws -> URL {
        let folder = try FileManager.default
            .url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("Downloads", isDirectory: true)

        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )

        let cleaned = sanitizeFilename(name)
        let ext = source.pathExtension.isEmpty ? "mp4" : source.pathExtension.lowercased()
        var destination = folder.appendingPathComponent("\(cleaned).\(ext)")
        var counter = 2

        while FileManager.default.fileExists(atPath: destination.path) {
            destination = folder.appendingPathComponent("\(cleaned) (\(counter)).\(ext)")
            counter += 1
        }

        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    private func sanitizeFilename(_ value: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = value
            .components(separatedBy: invalidCharacters)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return cleaned.isEmpty ? "Video" : String(cleaned.prefix(120))
    }
}

private enum TorrentAction: Equatable {
    case play
    case download
}

private struct PlayableURL: Identifiable {
    let url: URL
    let subtitles: [AddonSubtitle]
    let selectedSubtitle: AddonSubtitle?
    var id: String { url.absoluteString }
}

private struct TorrentPlayerSession: Identifiable {
    let id = UUID()
    let engine: TorrentEngine
    let subtitles: [AddonSubtitle]
    let selectedSubtitle: AddonSubtitle?
}
