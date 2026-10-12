import SwiftUI
import AVKit

struct TrackedPlayerView: View {
    let url: URL
    let item: MetaPreview
    let subtitles: [AddonSubtitle]
    let selectedSubtitle: AddonSubtitle?
    var bufferedProgress: Double? = nil
    var playbackDiagnostics: String? = nil
    /// Live torrent stats for the buffering badge, buffer bar and diagnostics.
    var torrentEngine: TorrentEngine? = nil
    var onPlaybackPosition: ((Double, Double) -> Void)? = nil
    var prepareSeek: ((Double) async -> Bool)? = nil
    var onPlaybackEvent: ((PlaybackMetricEvent) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryStore
    @AppStorage("playbox.player.verticalGestures") private var verticalGesturesEnabled = true
    @StateObject private var subtitleController = SubtitleOverlayController()
    @StateObject private var gestureController = PlaybackGestureController()
    @State private var player = AVPlayer()
    @State private var statusObserver: NSKeyValueObservation?
    @State private var failureObserver: NSObjectProtocol?
    @State private var endedObserver: NSObjectProtocol?
    @State private var playbackStatusObserver: NSKeyValueObservation?
    @State private var selectedPlaybackRate: Double = 1
    @State private var isSeeking = false
    @State private var pendingDirectSeekSeconds: Double?
    @State private var seekShouldResume = false
    @State private var seekID = UUID()
    @State private var seekMessage: String?
    @State private var errorMessage: String?
    @State private var isLoading = true
    @State private var isRebuffering = false
    @State private var isPreparingResume = false
    @State private var hasBegunPlayback = false
    @State private var hasEnded = false
    @State private var bufferedSeconds: Double = 0
    @State private var playbackSeconds: Double = 0
    @State private var lastReportedAt: Date = .distantPast
    @State private var lastStoredAt: Date = .distantPast
    @State private var progressTask: Task<Void, Never>?
    @State private var resumeTask: Task<Void, Never>?

    @ViewBuilder
    var body: some View {
        if url.isFileURL {
            VLCLocalTrackedPlayerView(
                url: url,
                item: item,
                subtitles: subtitles,
                selectedSubtitle: selectedSubtitle,
                bufferedProgress: bufferedProgress,
                playbackDiagnostics: playbackDiagnostics,
                torrentEngine: torrentEngine,
                onPlaybackPosition: onPlaybackPosition,
                prepareSeek: prepareSeek,
                onPlaybackEvent: onPlaybackEvent
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
            Color.black.ignoresSafeArea()
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
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(.black.opacity(0.58), in: Circle())
                    }
                    .accessibilityLabel("Close player")
                    Spacer(minLength: 0)
                    Button { seekDirect(seconds: -10) } label: {
                        Image(systemName: "gobackward.10").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Go back 10 seconds")
                    .disabled(player.currentItem == nil || errorMessage != nil)
                    Button { seekDirect(seconds: 10) } label: {
                        Image(systemName: "goforward.10").frame(width: 44, height: 44)
                    }
                    .accessibilityLabel("Skip forward 10 seconds")
                    .disabled(player.currentItem == nil || errorMessage != nil)
                    directSpeedMenu
                    ccMenu
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.top, 12)

                if let seekMessage {
                    Text(seekMessage)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(10)
                        .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 8))
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
                        .allowsHitTesting(false)
                }
            }

            PlaybackGestureHUD(controller: gestureController)

            if (isLoading || isRebuffering || isPreparingResume || isSeeking), errorMessage == nil {
                VStack(spacing: 12) {
                    ProgressView(isSeeking ? "Seeking video…" : (isPreparingResume ? "Resuming video…" : (isRebuffering ? "Buffering video…" : "Opening video…")))
                        .tint(.white)
                    if bufferedSeconds > 0 {
                        Text("\(Int(bufferedSeconds)) seconds ready to play")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.8))
                            .monospacedDigit()
                    }
                }
                .foregroundStyle(.white)
                .padding(22)
                .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 18))
                .allowsHitTesting(false)
            }

            if let errorMessage {
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle").font(.largeTitle)
                    Text("Playback failed").font(.headline)
                    Text(errorMessage)
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                    Button("Try Again") { Task { await startPlayback() } }
                        .buttonStyle(.borderedProminent)
                    Button("Close") { dismiss() }.buttonStyle(.bordered)
                }
                .foregroundStyle(.white)
                .padding(24)
                .background(.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 18))
                .padding(24)
            }
        }
        .preferredColorScheme(.dark)
    }

    private var directSpeedMenu: some View {
        Menu {
            ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { speed in
                Button {
                    selectedPlaybackRate = speed
                    if player.timeControlStatus == .playing { player.rate = Float(speed) }
                } label: {
                    let title = "\(String(format: "%g", speed))×"
                    if abs(selectedPlaybackRate - speed) < 0.01 {
                        Label(title, systemImage: "checkmark")
                    } else {
                        Text(title)
                    }
                }
            }
        } label: {
            Text("\(String(format: "%g", selectedPlaybackRate))×")
                .font(.subheadline.bold())
                .frame(minWidth: 44, minHeight: 44)
                .background(.black.opacity(0.58), in: Capsule())
        }
        .accessibilityLabel("Playback speed")
    }

    @MainActor
    private func seekDirect(seconds offset: Double) {
        guard let currentItem = player.currentItem, errorMessage == nil else { return }
        let duration = currentItem.duration.seconds
        let position = player.currentTime().seconds
        guard duration.isFinite, duration > 0, position.isFinite else { return }
        let targetSeconds = min(max((pendingDirectSeekSeconds ?? position) + offset, 0), max(0, duration - 0.1))
        let target = targetSeconds / duration
        if !isSeeking { seekShouldResume = isPreparingResume || player.timeControlStatus != .paused }
        let wasPlaying = seekShouldResume
        pendingDirectSeekSeconds = targetSeconds
        seekID = UUID()
        let requestID = seekID
        resumeTask?.cancel()
        currentItem.cancelPendingSeeks()
        isPreparingResume = false
        isSeeking = true
        seekMessage = nil
        player.pause()
        onPlaybackEvent?(.seekRequested(target))
        resumeTask = Task { @MainActor in
            let ready = await prepareSeek?(target) ?? true
            guard !Task.isCancelled, player.currentItem === currentItem, seekID == requestID else { return }
            var completed = false
            if ready {
                completed = await player.seek(to: CMTime(seconds: targetSeconds, preferredTimescale: 600))
            }
            guard !Task.isCancelled, player.currentItem === currentItem, seekID == requestID else { return }
            isSeeking = false
            pendingDirectSeekSeconds = nil
            if completed {
                hasEnded = false
                onPlaybackEvent?(.seekReady(target))
            } else {
                seekMessage = "The video could not seek to that position. Try again or choose another source."
                onPlaybackPosition?(position, duration)
            }
            if wasPlaying { playDirect() }
        }
    }

    @MainActor
    private func playDirect() {
        player.play()
        player.rate = Float(selectedPlaybackRate)
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
                .frame(width: 44, height: 44)
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
        isRebuffering = false
        isPreparingResume = false
        isSeeking = false
        pendingDirectSeekSeconds = nil
        seekShouldResume = false
        seekMessage = nil
        hasBegunPlayback = false
        hasEnded = false
        bufferedSeconds = 0
        playbackSeconds = 0
        lastReportedAt = .distantPast
        lastStoredAt = .distantPast
        onPlaybackEvent?(.opening)

        let asset = AVURLAsset(url: url, options: [
            AVURLAssetAllowsCellularAccessKey: true,
            AVURLAssetAllowsExpensiveNetworkAccessKey: true,
            AVURLAssetAllowsConstrainedNetworkAccessKey: true
        ])
        let playerItem = AVPlayerItem(asset: asset)
        playerItem.preferredForwardBufferDuration = 8
        player.replaceCurrentItem(with: playerItem)

        statusObserver = playerItem.observe(\.status, options: [.initial, .new]) { observed, _ in
            Task { @MainActor in
                guard player.currentItem === observed else { return }
                switch observed.status {
                case .readyToPlay:
                    errorMessage = nil
                    let resume = library.position(for: item)
                    if resume > 1, player.currentTime().seconds < 1 {
                        isPreparingResume = true
                        resumeTask?.cancel()
                        resumeTask = Task { @MainActor in
                            guard !Task.isCancelled, player.currentItem === observed, errorMessage == nil else { return }
                            let duration = observed.duration.seconds
                            if duration.isFinite, duration > 0 {
                                let target = min(max(resume / duration, 0), 0.999)
                                onPlaybackEvent?(.seekRequested(target))
                                let ready = await prepareSeek?(target) ?? true
                                guard !Task.isCancelled, player.currentItem === observed else { return }
                                if ready {
                                    let completed = await player.seek(to: CMTime(seconds: target * duration, preferredTimescale: 600))
                                    guard !Task.isCancelled, player.currentItem === observed else { return }
                                    if completed {
                                        onPlaybackEvent?(.seekReady(target))
                                    } else {
                                        seekMessage = "The saved position could not be restored. Playback will start from the current position."
                                    }
                                }
                            }
                            guard !Task.isCancelled, player.currentItem === observed, errorMessage == nil else { return }
                            isPreparingResume = false
                            playDirect()
                        }
                    } else {
                        playDirect()
                    }
                case .failed:
                    reportFailure(friendlyMessage(for: observed.error))
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
                guard player.currentItem === playerItem else { return }
                let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                reportFailure(friendlyMessage(for: error))
            }
        }
        endedObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { _ in
            Task { @MainActor in
                guard player.currentItem === playerItem else { return }
                hasEnded = true
                isRebuffering = false
                onPlaybackEvent?(.ended)
            }
        }

        playbackStatusObserver = player.observe(\.timeControlStatus, options: [.new]) { _, _ in
            Task { @MainActor in
                guard player.currentItem === playerItem else { return }
                if player.timeControlStatus == .playing, !isSeeking, !isPreparingResume {
                    if abs(Double(player.rate) - selectedPlaybackRate) > 0.01 {
                        player.rate = Float(selectedPlaybackRate)
                    }
                } else if player.timeControlStatus == .paused, !isSeeking, !isPreparingResume, hasBegunPlayback, !hasEnded {
                    isRebuffering = false
                    onPlaybackEvent?(.paused)
                }
            }
        }
        startProgressMonitor(playerItem)
        // The ready observer starts playback after applying the saved position.
    }

    @MainActor
    private func startProgressMonitor(_ playerItem: AVPlayerItem) {
        progressTask?.cancel()
        progressTask = Task { @MainActor in
            let beganAt = Date()
            var lastSeconds: Double = 0
            while !Task.isCancelled, player.currentItem === playerItem {
                let seconds = player.currentTime().seconds
                playbackSeconds = seconds.isFinite ? max(0, seconds) : 0
                bufferedSeconds = playerItem.loadedTimeRanges.reduce(0) { longest, range in
                    let start = range.timeRangeValue.start.seconds
                    let end = CMTimeRangeGetEnd(range.timeRangeValue).seconds
                    guard start.isFinite, end.isFinite,
                          start <= playbackSeconds + 0.1, end >= playbackSeconds else { return longest }
                    return max(longest, end - playbackSeconds)
                }

                if !isPreparingResume, !isSeeking, errorMessage == nil, !hasEnded {
                    let advancing = player.timeControlStatus == .playing && playbackSeconds > lastSeconds + 0.01
                    if advancing {
                        isLoading = false
                        if !hasBegunPlayback {
                            hasBegunPlayback = true
                            onPlaybackEvent?(.firstFrame)
                        }
                        if isRebuffering {
                            isRebuffering = false
                            onPlaybackEvent?(.resumed)
                        }
                    } else if hasBegunPlayback,
                              player.timeControlStatus == .waitingToPlayAtSpecifiedRate,
                              !isRebuffering {
                        isRebuffering = true
                        onPlaybackEvent?(.stalled)
                    }
                }
                lastSeconds = playbackSeconds

                let duration = playerItem.duration.seconds
                let now = Date()
                if hasBegunPlayback, !isPreparingResume, !isSeeking, errorMessage == nil,
                   duration.isFinite, duration > 0, playbackSeconds.isFinite {
                    if player.timeControlStatus == .playing, now.timeIntervalSince(lastReportedAt) >= 1 {
                        lastReportedAt = now
                        onPlaybackPosition?(playbackSeconds, duration)
                    }
                    if now.timeIntervalSince(lastStoredAt) >= 2 {
                        lastStoredAt = now
                        library.updatePlayback(item, position: playbackSeconds, duration: duration)
                    }
                }
                if now.timeIntervalSince(beganAt) > 20, playerItem.status == .unknown, errorMessage == nil {
                    reportFailure("The stream did not open within 20 seconds. Try another source or retry.")
                }

                do { try await Task.sleep(for: .milliseconds(250)) }
                catch { break }
            }
        }
    }

    @MainActor
    private func reportFailure(_ message: String) {
        guard errorMessage == nil else { return }
        errorMessage = message
        resumeTask?.cancel()
        resumeTask = nil
        player.currentItem?.cancelPendingSeeks()
        isPreparingResume = false
        isSeeking = false
        pendingDirectSeekSeconds = nil
        isLoading = false
        isRebuffering = false
        player.pause()
        onPlaybackEvent?(.failed(message))
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
        playbackStatusObserver?.invalidate()
        playbackStatusObserver = nil
        player.pause()
        seekID = UUID()
        statusObserver?.invalidate()
        statusObserver = nil
        if let failureObserver { NotificationCenter.default.removeObserver(failureObserver) }
        failureObserver = nil
        if let endedObserver { NotificationCenter.default.removeObserver(endedObserver) }
        endedObserver = nil
        progressTask?.cancel()
        progressTask = nil
        resumeTask?.cancel()
        resumeTask = nil
        player.currentItem?.cancelPendingSeeks()
        player.replaceCurrentItem(with: nil)
    }

    @MainActor
    private func stopPlayback() {
        let duration = player.currentItem?.duration.seconds ?? 0
        if hasBegunPlayback, !isPreparingResume, !isSeeking, errorMessage == nil, duration.isFinite, duration > 0 {
            library.updatePlayback(item, position: playbackSeconds, duration: duration)
        }
        cleanupCurrentItem()
    }
}
