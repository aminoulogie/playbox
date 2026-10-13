import SwiftUI

/// Small views that observe `TorrentEngine` directly. The engine publishes
/// ~15 times a second; keeping observation in these leaf views means only the stats
/// re-render, not the player or its video surface.
enum TorrentStatsFormat {
    // Fixed decimals so the digits tick visibly at ~15 updates per second,
    // like a download manager, instead of ByteCountFormatter's rounding.
    static func bytes(_ value: Int64) -> String {
        let bytes = Double(max(0, value))
        if bytes >= 1_000_000_000 { return String(format: "%.2f GB", bytes / 1_000_000_000) }
        if bytes >= 1_000_000 { return String(format: "%.2f MB", bytes / 1_000_000) }
        return String(format: "%.0f KB", bytes / 1_000)
    }

    static func speed(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond.isFinite, bytesPerSecond > 0 else { return "0 KB/s" }
        if bytesPerSecond >= 1_000_000 { return String(format: "%.2f MB/s", bytesPerSecond / 1_000_000) }
        return String(format: "%.0f KB/s", bytesPerSecond / 1_000)
    }
}

/// "3.4 MB/s · 128 MB" — download speed and downloaded data.
struct TorrentSpeedLine: View {
    @ObservedObject var engine: TorrentEngine
    var font: Font = .system(size: 15, weight: .semibold, design: .rounded)

    var body: some View {
        HStack(spacing: 8) {
            Label(TorrentStatsFormat.speed(engine.downloadSpeed), systemImage: "arrow.down")
            Text("·").foregroundStyle(.white.opacity(0.5))
            Text(TorrentStatsFormat.bytes(engine.downloadedBytes))
        }
        .font(font)
        .monospacedDigit()
        .foregroundStyle(.white)
        .lineLimit(1)
        .transaction { $0.animation = nil }
        .accessibilityElement(children: .combine)
    }
}

/// Startup screen shown until the first playable bytes are on disk.
struct TorrentStartupView: View {
    @ObservedObject var engine: TorrentEngine
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 14) {
            if case .failed(let message) = engine.state {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 40))
                    .foregroundStyle(.orange)
                Text(message)
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(4)
                    .frame(maxWidth: 320)
            } else {
                LoadingSpinner()
                    .frame(width: 60, height: 60)
                Text("\(Int((engine.cacheProgress * 100).rounded()))%")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                TorrentSpeedLine(engine: engine)
                Text(statusText)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.65))
            }

            Button("Close", action: onClose)
                .buttonStyle(.bordered)
                .tint(.white)
                .padding(.top, 6)
        }
        .padding(.horizontal, 24)
    }

    private var statusText: String {
        let peers = engine.peerCount == 1 ? "1 peer" : "\(engine.peerCount) peers"
        switch engine.state {
        case .idle, .resolving:
            return "Connecting · \(peers)"
        case .downloading:
            return "Buffering · \(peers)"
        case .ready:
            return "Starting…"
        case .failed:
            return ""
        }
    }
}

/// Buffer position bar under the player's scrubber.
struct TorrentBufferBar: View {
    @ObservedObject var engine: TorrentEngine

    var body: some View {
        if let progress = engine.bufferedProgress {
            BufferBar(progress: progress)
        }
    }
}

struct BufferBar: View {
    let progress: Double

    var body: some View {
        ProgressView(value: min(max(progress, 0), 1))
            .tint(.white.opacity(0.6))
            .accessibilityLabel("Estimated buffer position")
            .accessibilityValue("\(Int(min(max(progress, 0), 1) * 100)) percent")
    }
}

struct TorrentDiagnosticsText: View {
    @ObservedObject var engine: TorrentEngine

    var body: some View {
        if let progress = engine.bufferedProgress {
            Text("Estimated buffer position: \(Int(min(max(progress, 0), 1) * 100))%")
        }
        Text(engine.playbackDiagnostics)
            .font(.system(.body, design: .monospaced))
    }
}

struct LoadingSpinner: View {
    private let segmentCount = 12

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { context in
            let phase = Int(context.date.timeIntervalSinceReferenceDate * 12.0) % segmentCount
            GeometryReader { proxy in
                let side = min(proxy.size.width, proxy.size.height)
                ZStack {
                    ForEach(0..<segmentCount, id: \.self) { index in
                        Capsule(style: .continuous)
                            .fill(.white)
                            .frame(width: side * 0.08, height: side * 0.24)
                            .opacity(opacity(for: index, phase: phase))
                            .offset(y: -side * 0.32)
                            .rotationEffect(.degrees(Double(index) * 360.0 / Double(segmentCount)))
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
            }
        }
        .accessibilityHidden(true)
    }

    private func opacity(for index: Int, phase: Int) -> Double {
        let distance = (index - phase + segmentCount) % segmentCount
        return max(0.12, 1.0 - Double(distance) * 0.075)
    }
}
