import SwiftUI
import UIKit
import VLCKit

struct VLCLocalTrackedPlayerView: View {
    let url: URL
    let item: MetaPreview
    let subtitles: [AddonSubtitle]
    let selectedSubtitle: AddonSubtitle?
    var bufferedProgress: Double? = nil
    var playbackDiagnostics: String? = nil
    var onPlaybackPosition: ((Double, Double) -> Void)? = nil
    var prepareSeek: ((Double) async -> Bool)? = nil
    var onPlaybackEvent: ((PlaybackMetricEvent) -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var library: LibraryStore
    @AppStorage("playbox.player.verticalGestures") private var verticalGesturesEnabled = true
    @StateObject private var controller = VLCTorrentPlayerController()
    @StateObject private var subtitleController = SubtitleOverlayController()
    @StateObject private var gestureController = PlaybackGestureController()
    @State private var scrubValue: Double = 0
    @State private var isScrubbing = false
    @State private var controlsVisible = true
    @State private var lastInteraction = Date()
    @State private var showDiagnostics = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VLCVideoSurface(controller: controller)
                .ignoresSafeArea()

            PlaybackGestureLayer(
                controller: gestureController,
                enabled: verticalGesturesEnabled,
                onTap: {
                    withAnimation(.easeInOut(duration: 0.2)) { controlsVisible.toggle() }
                    lastInteraction = Date()
                }
            )
            .ignoresSafeArea()

            SystemVolumeHost(controller: gestureController)
                .frame(width: 1, height: 1)
                .opacity(0.001)
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                if controlsVisible {
                    HStack(spacing: 12) {
                        Button { dismiss() } label: {
                            Image(systemName: "xmark")
                                .frame(width: 44, height: 44)
                                .background(.black.opacity(0.55), in: Circle())
                        }
                        .accessibilityLabel("Close player")

                        Text(item.name)
                            .font(.headline)
                            .lineLimit(1)
                        Spacer()
                        Button {
                            showDiagnostics = true
                            keepControlsVisible()
                        } label: {
                            Image(systemName: "info.circle")
                                .frame(width: 44, height: 44)
                        }
                        .accessibilityLabel("Playback details")
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .background(LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom))
                }

                Spacer()

                if let subtitleText = subtitleController.text(at: controller.currentSeconds) {
                    Text(subtitleText)
                        .font(.system(size: 20, weight: .semibold))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .shadow(color: .black, radius: 3)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .background(.black.opacity(0.42), in: RoundedRectangle(cornerRadius: 8))
                        .padding(.horizontal, 24)
                        .padding(.bottom, controlsVisible ? 14 : 30)
                        .allowsHitTesting(false)
                }

                if controlsVisible {
                    playerControls
                        .transition(.opacity)
                }
            }

            PlaybackGestureHUD(controller: gestureController)

            if controller.errorMessage == nil, let status = controller.statusText {
                ProgressView(status)
                    .tint(.white)
                    .foregroundStyle(.white)
                    .padding(18)
                    .background(.black.opacity(0.75), in: RoundedRectangle(cornerRadius: 16))
                    .allowsHitTesting(false)
                    .accessibilityLabel(status)
            }

            if let message = controller.errorMessage {
                VStack(spacing: 14) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.largeTitle)
                    Text("Playback stopped").font(.headline)
                    Text(message)
                        .font(.subheadline)
                        .multilineTextAlignment(.center)
                    Button("Try Again") {
                        keepControlsVisible()
                        startPlayer(resumeSeconds: controller.currentSeconds)
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Close") { dismiss() }
                        .buttonStyle(.bordered)
                }
                .foregroundStyle(.white)
                .padding(24)
                .background(.black.opacity(0.88), in: RoundedRectangle(cornerRadius: 18))
                .padding(24)
            }
        }
        .preferredColorScheme(.dark)
        .sheet(isPresented: $showDiagnostics) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        Text("Player: VLC")
                        Text("State: \(controller.stateText)")
                        Text("Position: \(controller.currentTimeText) / \(controller.durationText)")
                        Text("Playback speed: \(String(format: "%g", controller.playbackRate))×")
                        if let progress = bufferedProgress {
                            Text("Available through: \(Int(min(max(progress, 0), 1) * 100))%")
                        }
                        if let playbackDiagnostics {
                            Text(playbackDiagnostics)
                                .font(.system(.body, design: .monospaced))
                        }
                        if let error = controller.errorMessage ?? controller.seekError {
                            Text(error).foregroundStyle(.orange)
                        }
                        Text("“Playback began” measures the first advance of the playback clock. Confirm visible first-frame timing on an iPhone before tuning buffering.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
                    .textSelection(.enabled)
                }
                .navigationTitle("Playback details")
                .toolbar { Button("Done") { showDiagnostics = false } }
            }
        }
        .task {
            subtitleController.select(selectedSubtitle)
            startPlayer(resumeSeconds: library.position(for: item))

            var ticks = 0
            while !Task.isCancelled {
                if controller.canRecordProgress {
                    ticks += 1
                    if ticks.isMultiple(of: 2) {
                        library.updatePlayback(item, position: controller.currentSeconds, duration: controller.durationSeconds)
                    }
                }
                if controlsVisible, controller.isPlaying,
                   !controller.isSeeking, !controller.isBuffering, !isScrubbing,
                   !showDiagnostics, !UIAccessibility.isVoiceOverRunning,
                   Date().timeIntervalSince(lastInteraction) > 5 {
                    withAnimation(.easeInOut(duration: 0.2)) { controlsVisible = false }
                }
                do { try await Task.sleep(for: .seconds(1)) }
                catch { break }
            }
        }
        .onChange(of: controller.isBuffering) { _, buffering in
            if buffering { keepControlsVisible() }
        }
        .onDisappear {
            if controller.canRecordProgress {
                library.updatePlayback(item, position: controller.currentSeconds, duration: controller.durationSeconds)
            }
            controller.stop()
        }
    }

    private var playerControls: some View {
        VStack(spacing: 10) {
            if let message = controller.seekError {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Slider(
                value: Binding(
                    get: { isScrubbing ? scrubValue : (controller.pendingSeekProgress ?? controller.progress) },
                    set: {
                        scrubValue = $0
                        isScrubbing = true
                        keepControlsVisible()
                    }
                ),
                in: 0...1,
                onEditingChanged: { editing in
                    keepControlsVisible()
                    if !editing {
                        controller.seek(to: scrubValue)
                        isScrubbing = false
                    }
                }
            )
            .disabled(controller.durationSeconds <= 0 || controller.errorMessage != nil)
            .accessibilityLabel("Playback position")
            .accessibilityValue("\(controller.currentTimeText) of \(controller.durationText)")

            if let progress = bufferedProgress {
                ProgressView(value: min(max(progress, 0), 1))
                    .tint(.white.opacity(0.6))
                    .accessibilityLabel("Torrent data available")
                    .accessibilityValue("\(Int(min(max(progress, 0), 1) * 100)) percent")
            }

            HStack {
                Text(controller.currentTimeText)
                Spacer()
                Text(controller.durationText)
            }
            .monospacedDigit()
            .font(.caption)
            .foregroundStyle(.white.opacity(0.8))

            HStack(spacing: 10) {
                ccMenu
                speedMenu
                Spacer(minLength: 0)
                Button {
                    keepControlsVisible()
                    controller.skip(seconds: -10)
                } label: {
                    Image(systemName: "gobackward.10").font(.title2).frame(width: 44, height: 44)
                }
                .disabled(controller.durationSeconds <= 0)
                .accessibilityLabel("Go back 10 seconds")

                Button {
                    keepControlsVisible()
                    controller.togglePlayback()
                } label: {
                    Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title)
                        .frame(width: 52, height: 52)
                }
                .accessibilityLabel(controller.isPlaying ? "Pause" : "Play")
                .disabled(controller.errorMessage != nil)

                Button {
                    keepControlsVisible()
                    controller.skip(seconds: 10)
                } label: {
                    Image(systemName: "goforward.10").font(.title2).frame(width: 44, height: 44)
                }
                .disabled(controller.durationSeconds <= 0)
                .accessibilityLabel("Skip forward 10 seconds")
                Spacer(minLength: 0)
            }
            .foregroundStyle(.white)
        }
        .padding()
        .background(.black.opacity(0.7))
    }

    private var speedMenu: some View {
        Menu {
            ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { speed in
                Button {
                    keepControlsVisible()
                    controller.setRate(speed)
                } label: {
                    let title = "\(String(format: "%g", speed))×"
                    if abs(controller.playbackRate - speed) < 0.01 {
                        Label(title, systemImage: "checkmark")
                    } else {
                        Text(title)
                    }
                }
            }
        } label: {
            Text("\(String(format: "%g", controller.playbackRate))×")
                .font(.subheadline.bold())
                .frame(minWidth: 44, minHeight: 44)
        }
        .accessibilityLabel("Playback speed")
    }

    @ViewBuilder
    private var ccMenu: some View {
        Menu {
            Button {
                subtitleController.select(nil)
                keepControlsVisible()
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
                    keepControlsVisible()
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
            Image(systemName: "captions.bubble").font(.title3).frame(width: 44, height: 44)
        }
        .disabled(subtitles.isEmpty)
        .opacity(subtitles.isEmpty ? 0.45 : 1)
        .accessibilityLabel("Subtitles")
    }

    private func keepControlsVisible() {
        controlsVisible = true
        lastInteraction = Date()
    }

    private func startPlayer(resumeSeconds: Double) {
        controller.prepareSeek = prepareSeek
        controller.onPlaybackPosition = onPlaybackPosition
        controller.onPlaybackEvent = onPlaybackEvent
        controller.start(url: url, resumeSeconds: resumeSeconds)
    }
}

private struct PlaybackGestureLayer: View {
    @ObservedObject var controller: PlaybackGestureController
    let enabled: Bool
    let onTap: () -> Void

    var body: some View {
        GeometryReader { proxy in
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(perform: onTap)
                .gesture(
                    DragGesture(minimumDistance: 8)
                        .onChanged { value in
                            guard enabled else { return }
                            controller.update(startX: value.startLocation.x, translation: value.translation, width: proxy.size.width)
                        }
                        .onEnded { _ in
                            guard enabled else { return }
                            controller.end()
                        }
                )
                .accessibilityAction(named: Text("Show or hide playback controls"), onTap)
        }
    }
}

private struct VLCVideoSurface: UIViewRepresentable {
    @ObservedObject var controller: VLCTorrentPlayerController

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        controller.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) { controller.attach(to: uiView) }
}

@MainActor
final class VLCTorrentPlayerController: NSObject, ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var isOpening = true
    @Published private(set) var isBuffering = false
    @Published private(set) var isSeeking = false
    @Published private(set) var pendingSeekProgress: Double?
    @Published private(set) var errorMessage: String?
    @Published private(set) var seekError: String?
    @Published private(set) var playbackRate: Double = 1
    @Published private(set) var currentMilliseconds: Int = 0
    @Published private(set) var durationMilliseconds: Int = 0

    var prepareSeek: ((Double) async -> Bool)?
    var onPlaybackPosition: ((Double, Double) -> Void)?
    var onPlaybackEvent: ((PlaybackMetricEvent) -> Void)?

    private let player = VLCMediaPlayer()
    private var pollTask: Task<Void, Never>?
    private var seekTask: Task<Void, Never>?
    private var pendingResumeSeconds: Double?
    private var hasBegunPlayback = false
    private var isActive = false
    private var userPaused = false
    private var lastAdvancedAt = Date()
    private var lastReportedAt = Date.distantPast
    private var lastClockMilliseconds = 0
    private var seekTargetSeconds: Double?
    private var seekAppliedAt: Date?
    private var sessionID = UUID()
    private var seekID = UUID()

    var currentSeconds: Double { Double(max(0, currentMilliseconds)) / 1000 }
    var durationSeconds: Double { Double(max(0, durationMilliseconds)) / 1000 }
    var canRecordProgress: Bool {
        hasBegunPlayback && !isSeeking && pendingResumeSeconds == nil && durationSeconds > 0
    }
    var progress: Double {
        guard durationMilliseconds > 0 else { return 0 }
        return min(max(Double(currentMilliseconds) / Double(durationMilliseconds), 0), 1)
    }
    var currentTimeText: String { Self.format(milliseconds: currentMilliseconds) }
    var durationText: String { Self.format(milliseconds: durationMilliseconds) }
    var statusText: String? {
        if isSeeking { return "Preparing this part of the video…" }
        if isOpening { return "Opening video…" }
        if isBuffering { return "Buffering video…" }
        return nil
    }
    var stateText: String {
        if let statusText { return statusText }
        if errorMessage != nil { return "Stopped with an error" }
        return isPlaying ? "Playing" : "Paused"
    }

    override init() {
        super.init()
        player.delegate = self
    }

    func attach(to view: UIView) {
        if (player.drawable as? UIView) !== view { player.drawable = view }
    }

    func start(url: URL, resumeSeconds: Double) {
        stop()
        sessionID = UUID()
        isOpening = true
        isActive = true
        userPaused = false
        errorMessage = nil
        seekError = nil
        currentMilliseconds = 0
        durationMilliseconds = 0
        hasBegunPlayback = false
        lastClockMilliseconds = 0
        lastAdvancedAt = Date()
        lastReportedAt = .distantPast
        pendingResumeSeconds = resumeSeconds.isFinite && resumeSeconds > 1 ? resumeSeconds : nil
        onPlaybackEvent?(.opening)

        guard let media = VLCMedia(url: url) else {
            fail("VLC could not open this video. Try another source.")
            return
        }
        // Retain existing caches until device timing can guide tuning.
        media.addOptions(["file-caching": 1000, "network-caching": 2500])
        player.media = media
        player.play()
        player.rate = Float(playbackRate)

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                self.refresh()
                do { try await Task.sleep(for: .milliseconds(250)) }
                catch { break }
            }
        }
    }

    func togglePlayback() {
        guard isActive, errorMessage == nil else { return }
        userPaused.toggle()
        if userPaused {
            player.pause()
        } else if !isSeeking {
            lastAdvancedAt = Date()
            player.play()
            player.rate = Float(playbackRate)
        }
        isPlaying = !userPaused && !isSeeking
    }

    func setRate(_ rate: Double) {
        guard rate.isFinite else { return }
        playbackRate = min(max(rate, 0.5), 2)
        player.rate = Float(playbackRate)
    }

    func skip(seconds: Double) {
        guard durationSeconds > 0 else { return }
        let origin = (pendingSeekProgress ?? progress) * durationSeconds
        seek(to: (origin + seconds) / durationSeconds)
    }

    func seek(to progress: Double) {
        guard isActive, durationSeconds > 0, progress.isFinite else { return }
        let target = min(max(progress, 0), 0.999)
        seekTask?.cancel()
        seekID = UUID()
        let requestID = seekID
        let activeSession = sessionID
        let previousSeconds = currentSeconds
        pendingResumeSeconds = nil
        pendingSeekProgress = target
        isSeeking = true
        seekError = nil
        seekTargetSeconds = nil
        seekAppliedAt = nil
        player.pause()
        isPlaying = false
        onPlaybackEvent?(.seekRequested(target))

        seekTask = Task { [weak self] in
            guard let self else { return }
            let ready = await self.prepareSeek?(target) ?? true
            guard !Task.isCancelled, self.isActive, self.sessionID == activeSession,
                  self.seekID == requestID else { return }
            if !ready {
                self.isSeeking = false
                self.pendingSeekProgress = nil
                self.seekError = "This part of the video is not ready. Try seeking again after more data arrives."
                // Restore torrent priorities to the current playback area after a failed seek.
                self.onPlaybackPosition?(previousSeconds, self.durationSeconds)
                if !self.userPaused { self.player.play() }
                self.lastAdvancedAt = Date()
                return
            }
            self.player.position = target
            self.seekTargetSeconds = target * self.durationSeconds
            self.seekAppliedAt = Date()
            self.lastAdvancedAt = Date()
            self.onPlaybackEvent?(.seekReady(target))
            if !self.userPaused {
                self.player.play()
                self.player.rate = Float(self.playbackRate)
            }
        }
    }

    func stop() {
        isActive = false
        sessionID = UUID()
        seekID = UUID()
        pollTask?.cancel()
        pollTask = nil
        seekTask?.cancel()
        seekTask = nil
        player.stop()
        player.media = nil
        isPlaying = false
        isOpening = false
        isBuffering = false
        isSeeking = false
        pendingSeekProgress = nil
        pendingResumeSeconds = nil
        seekTargetSeconds = nil
        seekAppliedAt = nil
    }

    private func refresh() {
        guard isActive else { return }
        currentMilliseconds = max(0, Int(player.time.intValue))
        durationMilliseconds = max(0, Int(player.media?.length.intValue ?? 0))
        let now = Date()

        if player.state == .error {
            fail("VLC could not continue this video. The source may be incomplete or unsupported.")
            return
        }

        if let resume = pendingResumeSeconds, durationSeconds > 0,
           player.state == .playing || player.state == .paused {
            seek(to: min(resume / durationSeconds, 0.999))
        }

        if isSeeking, let target = seekTargetSeconds, let appliedAt = seekAppliedAt {
            if abs(currentSeconds - target) < 2 {
                isSeeking = false
                pendingSeekProgress = nil
                seekTargetSeconds = nil
                seekAppliedAt = nil
                lastAdvancedAt = now
                lastClockMilliseconds = currentMilliseconds
            } else if now.timeIntervalSince(appliedAt) > 8 {
                isSeeking = false
                pendingSeekProgress = nil
                seekTargetSeconds = nil
                seekAppliedAt = nil
                seekError = "The player could not seek to that position. Try another position or source."
                onPlaybackPosition?(currentSeconds, durationSeconds)
                lastAdvancedAt = now
            }
        }

        isPlaying = player.isPlaying && !userPaused && !isSeeking
        let advanced = currentMilliseconds > lastClockMilliseconds + 20
        if advanced, !isSeeking, pendingResumeSeconds == nil {
            lastAdvancedAt = now
            if !hasBegunPlayback, !userPaused {
                hasBegunPlayback = true
                isOpening = false
                onPlaybackEvent?(.firstFrame)
            }
            if isBuffering, !userPaused {
                isBuffering = false
                onPlaybackEvent?(.resumed)
            }
        }
        lastClockMilliseconds = currentMilliseconds

        if hasBegunPlayback, !userPaused, !isSeeking,
           now.timeIntervalSince(lastAdvancedAt) > 2.5, !isBuffering {
            isBuffering = true
            onPlaybackEvent?(.stalled)
        }

        if isPlaying, canRecordProgress, now.timeIntervalSince(lastReportedAt) >= 1 {
            lastReportedAt = now
            onPlaybackPosition?(currentSeconds, durationSeconds)
        }

        if !hasBegunPlayback, player.state == .stopped, !isSeeking,
           now.timeIntervalSince(lastAdvancedAt) > 3, errorMessage == nil {
            fail("VLC stopped while opening this video. Wait for more data and try again, or choose another source.")
            return
        }

        if hasBegunPlayback, player.state == .stopped, !isSeeking, errorMessage == nil {
            if durationSeconds > 0, currentSeconds >= durationSeconds - 2 {
                isBuffering = false
                isPlaying = false
                onPlaybackEvent?(.ended)
                isActive = false
            } else {
                fail("The video stopped before its end. Wait for more torrent data and try again.")
            }
        }
    }

    private func fail(_ message: String) {
        guard isActive, errorMessage == nil else { return }
        errorMessage = message
        isActive = false
        seekTask?.cancel()
        seekTask = nil
        pollTask?.cancel()
        pollTask = nil
        player.pause()
        isOpening = false
        isBuffering = false
        isPlaying = false
        isSeeking = false
        pendingSeekProgress = nil
        onPlaybackEvent?(.failed(message))
    }

    private static func format(milliseconds: Int) -> String {
        let totalSeconds = max(0, milliseconds / 1000)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, seconds)
            : String(format: "%02d:%02d", minutes, seconds)
    }
}

extension VLCTorrentPlayerController: VLCMediaPlayerDelegate {
    nonisolated func mediaPlayerStateChanged(_ newState: VLCMediaPlayerState) {
        Task { @MainActor [weak self] in
            self?.refresh()
        }
    }

    nonisolated func mediaPlayerTimeChanged(_ aNotification: Notification) {
        Task { @MainActor [weak self] in
            self?.refresh()
        }
    }

    nonisolated func mediaPlayerBufferingChanged(_ progress: Float) {
        Task { @MainActor [weak self] in
            guard let self, self.isActive, !self.isSeeking, !self.userPaused else { return }
            if progress < 1, self.hasBegunPlayback, !self.isBuffering {
                self.isBuffering = true
                self.onPlaybackEvent?(.stalled)
            }
            // Resume is reported when the playback clock advances again.
        }
    }
}
