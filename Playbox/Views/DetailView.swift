import SwiftUI
import AVKit

struct DetailView: View {
    @EnvironmentObject private var store: AddonStore
    let item: MetaPreview

    @State private var streams: [AddonStream] = []
    @State private var playerURL: PlayableURL?

    var body: some View {
        List {
            if let description = item.description {
                Section("About") { Text(description) }
            }

            Section("Sources") {
                if streams.isEmpty {
                    Text("No sources loaded.").foregroundStyle(.secondary)
                }

                ForEach(streams) { stream in
                    Button {
                        if let url = stream.playableURL {
                            playerURL = PlayableURL(url: url)
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(stream.title ?? stream.name ?? "Source")
                            Text(stream.isTorrent ? "Torrent source" : "HTTP/HLS")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .disabled(stream.playableURL == nil)
                }
            }
        }
        .navigationTitle(item.name)
        .task { await loadStreams() }
        .sheet(item: $playerURL) { value in
            VideoPlayer(player: AVPlayer(url: value.url))
                .ignoresSafeArea()
        }
    }

    private func loadStreams() async {
        var combined: [AddonStream] = []
        for addon in store.addons {
            if let result = try? await AddonClient().streams(
                baseURL: addon.baseURL,
                type: item.type,
                id: item.id
            ) {
                combined.append(contentsOf: result)
            }
        }
        streams = combined
    }
}

private struct PlayableURL: Identifiable {
    let url: URL
    var id: String { url.absoluteString }
}
