import SwiftUI
import VideoPlayer

struct DetailView: View {
    @EnvironmentObject private var store: AddonStore
    let item: MetaPreview

    @State private var metadata: MetaPreview?
    @State private var streams: [AddonStream] = []
    @State private var subtitles: [AddonSubtitle] = []
    @State private var selectedSubtitle: AddonSubtitle?
    @State private var playerURL: PlayableURL?
    @State private var isPlaying = true

    private let cinemeta = URL(string: "https://v3-cinemeta.strem.io")!

    var body: some View {
        List {
            Section {
                HStack(alignment: .top, spacing: 16) {
                    AsyncImage(url: (metadata?.poster ?? item.poster).flatMap(URL.init(string:))) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        Rectangle().fill(.gray.opacity(0.2))
                    }
                    .frame(width: 110, height: 165)
                    .clipped()
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                    VStack(alignment: .leading, spacing: 8) {
                        Text(metadata?.name ?? item.name).font(.title2.bold())
                        if let rating = metadata?.imdbRating ?? item.imdbRating {
                            Label("\(rating)/10 IMDb", systemImage: "star.fill")
                                .font(.subheadline)
                        }
                        if let release = metadata?.releaseInfo ?? item.releaseInfo {
                            Text(release).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if let description = metadata?.description ?? item.description {
                Section("About") { Text(description) }
            }

            if !subtitles.isEmpty {
                Section("CC / Subtitles") {
                    Picker("Subtitle", selection: $selectedSubtitle) {
                        Text("Off").tag(nil as AddonSubtitle?)
                        ForEach(subtitles, id: \.stableID) { subtitle in
                            Text(subtitle.lang?.uppercased() ?? "CC")
                                .tag(subtitle as AddonSubtitle?)
                        }
                    }
                }
            }

            Section("Play") {
                if streams.isEmpty {
                    Text("No playable sources returned.")
                        .foregroundStyle(.secondary)
                }
                ForEach(streams) { stream in
                    Button {
                        guard let url = stream.playableURL else { return }
                        playerURL = PlayableURL(url: url)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(stream.title ?? stream.name ?? "Source")
                            Label(
                                stream.isTorrent ? "Torrent source — external stream bridge required" : "Play",
                                systemImage: stream.playableURL == nil ? "lock.slash" : "play.fill"
                            )
                            .font(.caption)
                            .foregroundStyle(stream.playableURL == nil ? .secondary : .blue)
                        }
                    }
                    .disabled(stream.playableURL == nil)
                }
            }
        }
        .navigationTitle(item.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadDetails() }
        .sheet(item: $playerURL) { value in
            VStack(spacing: 0) {
                VideoPlayer(url: value.url, play: $isPlaying)
                    .autoReplay(false)
                    .mute(false)
                    .ignoresSafeArea()
                if let subtitle = selectedSubtitle {
                    Text("CC: \(subtitle.lang?.uppercased() ?? "Subtitle") selected")
                        .font(.caption)
                        .padding(8)
                }
            }
        }
    }

    private func loadDetails() async {
        metadata = try? await AddonClient().meta(
            baseURL: cinemeta, type: item.type, id: item.id
        )

        var foundStreams: [AddonStream] = []
        var foundSubtitles: [AddonSubtitle] = []

        await withTaskGroup(of: ([AddonStream], [AddonSubtitle]).self) { group in
            for addon in store.addons {
                group.addTask {
                    async let streamResult = try? AddonClient().streams(
                        baseURL: addon.baseURL, type: item.type, id: item.id
                    )
                    async let subtitleResult = try? AddonClient().subtitles(
                        baseURL: addon.baseURL, type: item.type, id: item.id
                    )
                    return (await streamResult ?? [], await subtitleResult ?? [])
                }
            }
            for await result in group {
                foundStreams.append(contentsOf: result.0)
                foundSubtitles.append(contentsOf: result.1)
            }
        }

        streams = Array(Set(foundStreams))
        subtitles = Array(Set(foundSubtitles))
            .sorted { ($0.lang ?? "") < ($1.lang ?? "") }
    }
}

private struct PlayableURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
