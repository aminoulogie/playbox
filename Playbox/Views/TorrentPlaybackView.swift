import SwiftUI

struct TorrentPlaybackView: View {
    @ObservedObject var engine: TorrentEngine
    let item: MetaPreview
    let subtitles: [AddonSubtitle]
    let selectedSubtitle: AddonSubtitle?

    @Environment(\.dismiss) private var dismiss
    @State private var streamURL: URL?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let streamURL {
                TrackedPlayerView(
                    url: streamURL,
                    item: item,
                    subtitles: subtitles,
                    selectedSubtitle: selectedSubtitle
                )
                .ignoresSafeArea()
            } else {
                VStack(spacing: 11) {
                    SegmentedLoadingSpinner()
                        .frame(width: 68, height: 68)
                        .padding(.bottom, 2)

                    Text("Cache loading")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.white.opacity(0.78))

                    Text(String(format: "%.2f%%", engine.cacheProgress * 100))
                        .font(.system(size: 27, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .foregroundStyle(.white)

                    Text(formatSpeed(engine.downloadSpeed))
                        .font(.system(size: 14, weight: .medium))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .foregroundStyle(.white.opacity(0.9))

                    Text(statusTitle)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.76))

                    Text("Downloaded: \(String(format: "%.2f", engine.progress * 100))% · \(engine.peerCount) peers")
                        .font(.system(size: 13))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .foregroundStyle(.white.opacity(0.84))

                    Text(engine.diagnosticText)
                        .font(.system(size: 10.5))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white.opacity(0.56))
                        .lineLimit(4)
                        .frame(maxWidth: 350)
                        .padding(.top, 3)

                    Button("Close") {
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)
                    .font(.system(size: 14, weight: .medium))
                    .padding(.top, 5)
                }
                .padding(.horizontal, 24)
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
            return engine.cacheProgress >= 0.70
                ? "Finalizing playback cache…"
                : "Buffering video…"
        case .ready:
            return "Opening player…"
        case .failed(let message):
            return message
        }
    }
}

private struct SegmentedLoadingSpinner: View {
    private let segmentCount = 12

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.04)) { context in
            let phase = Int(context.date.timeIntervalSinceReferenceDate * 12.0) % segmentCount

            ZStack {
                ForEach(0..<segmentCount, id: \.self) { index in
                    Capsule(style: .continuous)
                        .fill(.white)
                        .frame(width: 5.5, height: 16)
                        .opacity(opacity(for: index, phase: phase))
                        .offset(y: -22)
                        .rotationEffect(.degrees(Double(index) * 360.0 / Double(segmentCount)))
                }
            }
        }
    }

    private func opacity(for index: Int, phase: Int) -> Double {
        let distance = (index - phase + segmentCount) % segmentCount
        return max(0.12, 1.0 - Double(distance) * 0.075)
    }
}
