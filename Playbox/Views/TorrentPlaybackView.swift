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
                    ZStack {
                        Circle()
                            .stroke(.white.opacity(0.18), lineWidth: 8)
                        Circle()
                            .trim(from: 0, to: max(0.001, engine.cacheProgress))
                            .stroke(.white, style: StrokeStyle(lineWidth: 8, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 0.1), value: engine.cacheProgress)
                    }
                    .frame(width: 116, height: 116)

                    Text("Cache loading")
                        .font(.headline)
                        .foregroundStyle(.white.opacity(0.78))

                    Text(String(format: "%.2f%%", engine.cacheProgress * 100))
                        .font(.system(size: 42, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white)

                    Text(formatSpeed(engine.downloadSpeed))
                        .font(.title3)
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(0.9))

                    Text(statusTitle)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.78))

                    Text("Downloaded: \(String(format: "%.2f", engine.progress * 100))% · \(engine.peerCount) peers")
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

    private func formatSpeed(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 0 else { return "0 B/s" }
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: Int64(bytesPerSecond)) + "/s"
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
