import SwiftUI

struct TorrentPlaybackView: View {
    // Not observed here: live stats re-render only the leaf views that read
    // them, so the player and its video surface are not rebuilt every 100 ms.
    let engine: TorrentEngine
    let item: MetaPreview
    let subtitles: [AddonSubtitle]
    let selectedSubtitle: AddonSubtitle?

    @Environment(\.dismiss) private var dismiss
    @State private var streamURL: URL?
    @State private var failureMessage: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let streamURL {
                TrackedPlayerView(
                    url: streamURL,
                    item: item,
                    subtitles: subtitles,
                    selectedSubtitle: selectedSubtitle,
                    torrentEngine: engine,
                    onPlaybackPosition: { [engine] seconds, duration in
                        engine.reportPlaybackPosition(seconds: seconds, duration: duration)
                    },
                    prepareSeek: { [engine] position in
                        await engine.prepareSeek(to: position)
                    },
                    onPlaybackEvent: { [engine] event in
                        engine.recordPlaybackEvent(event)
                    }
                )
                .ignoresSafeArea()
            } else {
                TorrentStartupView(engine: engine) { dismiss() }
            }
        }
        .overlay {
            if streamURL != nil, let failureMessage {
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                    Text("Torrent source stopped").font(.headline)
                    Text(failureMessage).font(.subheadline).multilineTextAlignment(.center)
                    Button("Choose another source") { dismiss() }
                        .buttonStyle(.borderedProminent)
                }
                .foregroundStyle(.white)
                .padding(24)
                .background(.black.opacity(0.9), in: RoundedRectangle(cornerRadius: 18))
                .padding(24)
            }
        }
        .onReceive(engine.$state.removeDuplicates()) { state in
            switch state {
            case .ready(let url) where streamURL == nil:
                streamURL = url
            case .failed(let message):
                failureMessage = message
            default:
                break
            }
        }
    }
}
