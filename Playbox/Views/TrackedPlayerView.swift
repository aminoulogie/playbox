import SwiftUI
import AVKit

struct TrackedPlayerView: View {
    let url: URL
    let item: MetaPreview
    let subtitles: [AddonSubtitle]
    let selectedSubtitle: AddonSubtitle?

    @EnvironmentObject private var library: LibraryStore
    @AppStorage("playbox.player.verticalGestures") private var verticalGesturesEnabled = true
    @StateObject private var subtitleController = SubtitleOverlayController()
    @StateObject private var gestureController = PlaybackGestureController()
    @State private var player = AVPlayer()
    @State private var observer: Any?
    @State private var statusObserver: NSKeyValueObservation?
    @State private var failureObserver: NSObjectProtocol?
    @State private var errorMessage: String?
    @State private var isLoading = true
    @State private var currentProgress: Double = 0
    @State private var currentSpeed: Double = 0
    @State private var playbackSeconds: Double = 0
    @State private var lastLoaded: Int64 = 0
    @State private var lastSpeedUpdate: Date = Date()
    @State private var progressTask: Task<Void, Never>?

    @ViewBuilder
    var body: some View {
        if url.isFileURL {
            VLCLocalTrackedPlayerView(
                url: url,
                item: item,
                subtitles: subtitles,
                selectedSubtitle: selectedSubtitle
            )
        } else {
            directPlayer
                .task {
                    subtitleController.select(selectedSubtitle)
                    await startPlayback()
                }
                .onDisappear { stopPlayback() }
        }
    }

    private var directPlayer: some View {
        ZStack {
            GeometryReader { proxy in
                VideoPlayer(player: player)
                    .ignoresSafeArea()
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 8)
                            .onChanged { value in
                                guard verticalGesturesEnabled else { return }
                                gestureController.update(
                                    startX: value.startLocation.x,
                                    translation: value.translation,
                                    width: proxy.size.width
                                )
                            }
                            .onEnded { _ in
                                guard verticalGesturesEnabled else { return }
                                gestureController.end()
                            }
                    )
            }

            SystemVolumeHost(controller: gestureController)
                .frame(width: 1, height: 1)
                .opacity(0.001)
                .allowsHitTesting(false)

            VStack {
                HStack {
                    Spacer()
                    ccMenu
                        .padding(.trailing, 18)
                        .padding(.top, 12)
                }

                Spacer()

                if let subtitleText = subtitleController.text(at: playbackSeconds) {
                    Text(subtitleText)
                        .font(.system(size: 20, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .shadow(color: .black, radius: 3)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.42), in: RoundedRectangle(cornerRadius: 8))
                        .padding(.horizontal, 24)
                        .padding(.bottom, 54)
                }
            }

            PlaybackGestureHUD(controller: gestureController)

            if isLoading && errorMessage == nil {
                VStack(spacing: 18) {
                    ZStack {
                        Circle()
                            .stroke(Color.white.opacity(0.2), lineWidth: 8)
                            .frame(width: 126, height: 126)

                        Circle()
                            .trim(from: 0, to: max(0.01, min(currentProgress, 1.0)))
                            .stroke(
                                AngularGradient(
                                    gradient: Gradient(colors: [.blue, .cyan, .white]),
                                    center: .center
                                ),
                                style: StrokeStyle(lineWidth: 8, lineCap: .round)
                            )
                            .frame(width: 126, height: 126)
                            .rotationEffect(.degrees(-90))
                            .animation(.linear(duration: 0.12), value: currentProgress)

                        VStack(spacing: 6) {
                            Text(String(format: "%.2f%%", currentProgress * 100))
                                .font(.system(size: 24, weight: .bold, design: .rounded))
                                .monospacedDigit()
                            Text("Loading")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                    }

                    HStack(spacing: 8) {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 12, weight: .semibold))
                        Text(formatSpeed(currentSpeed))
                            .font(.system(size: 13, weight: .medium))
                            .monospacedDigit()
                    }
                    .foregroundStyle(.white.opacity(0.9))
                }
                .padding(22)
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 26))
            }

            if let errorMessage {
                VStack(spacing: 14) {
                    ContentUnavailableView(
                        "Playback failed",
                        systemImage: "exclamationmark.triangle",
                        description: Text(errorMessage)
                    )
                    Button("Try Again") { Task { await startPlayback() } }
                        .buttonStyle(.borderedProminent)
                }
                .padding()
                .background(.ultraThinMaterial)
            }
        }
    }

    @ViewBuilder
    private var ccMenu: some View {
        Menu {
            Button {
                subtitleController.select(nil)
            } label: {
                if subtitleController.selectedID == nil {
                    Label("Off", systemImage: "checkmark")
                } else {
                    Text("Off")
                }
            }

            ForEach(subtitles, id: \.stableID) { subtitle in
                Button {
                    subtitleController.select(subtitle)
                } label: {
                    let title = subtitle.lang?.uppercased() ?? "CC"
                    if subtitleController.selectedID == subtitle.stableID {
                        Label(title, systemImage: "checkmark")
                    } else {
                        Text(title)
                    }
                }
            }
        } label: {
            Image(systemName: "captions.bubble.fill")
                .font(.title3)
                .foregroundStyle(.white)
                .padding(10)
                .background(.black.opacity(0.58), in: Circle())
        }
        .disabled(subtitles.isEmpty)
        .opacity(subtitles.isEmpty ? 0.45 : 1)
        .accessibilityLabel("Subtitles")
    }

    @MainActor
    private func startPlayback() async {
        cleanupCurrentItem()
        errorMessage = nil
        isLoading = true
        currentProgress = 0
        currentSpeed = 0
        playbackSeconds = 0
        lastLoaded = 0
        lastSpeedUpdate = Date()

        let asset = AVURLAsset(url: url, options: [
            AVURLAssetAllowsCellularAccessKey: true,
            AVURLAssetAllowsExpensiveNetworkAccessKey: true,
            AVURLAssetAllowsConstrainedNetworkAccessKey: true
        ])
        let playerItem = AVPlayerItem(asset: asset)
        playerItem.preferredForwardBufferDuration = 8

        statusObserver = playerItem.observe(\.status, options: [.initial, .new]) { observed, _ in
            Task { @MainActor in
                guard player.currentItem === observed else { return }
                switch observed.status {
                case .readyToPlay:
                    isLoading = false
                    errorMessage = nil
                    let resume = library.position(for: item)
                    if resume > 0, player.currentTime().seconds < 1 {
                        await player.seek(to: CMTime(seconds: resume, preferredTimescale: 600))
                    }
                    player.play()
                case .failed:
                    isLoading = false
                    errorMessage = friendlyMessage(for: observed.error)
                case .unknown:
                    break
                @unknown default:
                    break
                }
            }
        }

        failureObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemFailedToPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { note in
            Task { @MainActor in
                let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                errorMessage = friendlyMessage(for: error)
                isLoading = false
            }
        }

        player.replaceCurrentItem(with: playerItem)
        observer = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 2, preferredTimescale: 600),
            queue: .main
        ) { time in
            Task { @MainActor in
                let duration = CMTimeGetSeconds(player.currentItem?.duration ?? .invalid)
                library.updatePlayback(item, position: CMTimeGetSeconds(time), duration: duration)
            }
        }

        startProgressMonitor(playerItem)
        player.play()

        try? await Task.sleep(for: .seconds(20))
        if player.currentItem === playerItem, playerItem.status == .unknown {
            isLoading = false
            errorMessage = "The stream did not start within 20 seconds. The server may be unavailable or the media format may not be supported."
        }
    }

    private func startProgressMonitor(_ playerItem: AVPlayerItem) {
        progressTask?.cancel()
        progressTask = Task {
            while !Task.isCancelled {
                let ranges = playerItem.loadedTimeRanges
                let loaded = ranges.reduce(Int64(0)) { total, range in
                    total + Int64(range.timeRangeValue.duration.value)
                }

                let duration = playerItem.duration
                let progress = duration.value > 0 ? Double(loaded) / Double(duration.value) : 0
                let seconds = player.currentTime().seconds

                await MainActor.run {
                    playbackSeconds = seconds.isFinite ? max(0, seconds) : 0

                    let now = Date()
                    let delta = now.timeIntervalSince(lastSpeedUpdate)
                    if delta >= 0.1 {
                        let bytesDelta = loaded - lastLoaded
                        let speed = delta > 0 ? Double(bytesDelta) / delta : 0
                        currentSpeed = speed
                        lastLoaded = loaded
                        lastSpeedUpdate = now
                    }
                    currentProgress = min(max(progress, 0), 1)
                }

                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private func formatSpeed(_ value: Double) -> String {
        let units = ["B/s", "KB/s", "MB/s", "GB/s"]
        var current = value
        var index = 0
        while current >= 1024 && index < units.count - 1 {
            current /= 1024
            index += 1
        }
        return String(format: "%.2f %@", current, units[index])
    }

    @MainActor
    private func friendlyMessage(for error: Error?) -> String {
        guard let error else {
            return "iOS could not open this direct stream. The server, container, or codec may be incompatible."
        }
        let ns = error as NSError
        let text = error.localizedDescription
        if ns.domain == AVFoundationErrorDomain || text.localizedCaseInsensitiveContains("operation stopped") {
            return "iOS could not decode or continue this stream. Try another direct source; its container or codec may be incompatible."
        }
        return text
    }

    @MainActor
    private func cleanupCurrentItem() {
        player.pause()
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
        statusObserver?.invalidate()
        statusObserver = nil
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        failureObserver = nil
        progressTask?.cancel()
        progressTask = nil
        player.replaceCurrentItem(with: nil)
    }

    @MainActor
    private func stopPlayback() {
        cleanupCurrentItem()
    }
}
