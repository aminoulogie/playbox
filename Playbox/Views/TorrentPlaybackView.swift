import SwiftUI

struct TorrentPlaybackView: View {
    @ObservedObject var engine: TorrentEngine
    let item: MetaPreview

    @Environment(\.dismiss) private var dismiss
    @State private var streamURL: URL?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let streamURL {
                TrackedPlayerView(url: streamURL, item: item)
                    .ignoresSafeArea()
            } else {
                VStack(spacing: 18) {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)

                    Text(statusTitle)
                        .font(.headline)
                        .foregroundStyle(.white)

                    if engine.progress > 0 {
                        ProgressView(value: engine.progress)
                            .tint(.white)
                            .frame(maxWidth: 280)
                    }

                    Text("\(Int(engine.progress * 100))% · \(engine.peerCount) peers")
                        .font(.subheadline)
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.85))

                    Text(engine.diagnosticText)
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.65))
                        .lineLimit(5)
                        .frame(maxWidth: 420)

                    Button("Close") {
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                }
                .padding(28)
            }
        }
        .onReceive(engine.$state) { state in
            guard streamURL == nil else { return }
            if case .ready(let url) = state {
                streamURL = url
            }
        }
    }

    private var statusTitle: String {
        switch engine.state {
        case .idle:
            return "Preparing stream…"
        case .resolving:
            return "Finding torrent metadata…"
        case .downloading:
            return "Buffering video…"
        case .ready:
            return "Opening player…"
        case .failed(let message):
            return message
        }
    }
}
