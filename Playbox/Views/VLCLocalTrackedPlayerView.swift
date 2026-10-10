import SwiftUI
import UIKit
import VLCKit

struct VLCLocalTrackedPlayerView: View {
    let url: URL
    let item: MetaPreview

    @EnvironmentObject private var library: LibraryStore
    @StateObject private var controller = VLCTorrentPlayerController()
    @State private var scrubValue: Double = 0
    @State private var isScrubbing = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VLCVideoSurface(controller: controller)
                .ignoresSafeArea()

            VStack {
                Spacer()

                VStack(spacing: 12) {
                    Slider(
                        value: Binding(
                            get: {
                                if isScrubbing { return scrubValue }
                                return controller.progress
                            },
                            set: {
                                scrubValue = $0
                                isScrubbing = true
                            }
                        ),
                        in: 0...1,
                        onEditingChanged: { editing in
                            if !editing {
                                controller.seek(to: scrubValue)
                                isScrubbing = false
                            }
                        }
                    )

                    HStack(spacing: 16) {
                        Text(controller.currentTimeText)
                            .monospacedDigit()
                            .font(.caption)

                        Spacer()

                        Button {
                            controller.togglePlayback()
                        } label: {
                            Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                                .font(.title2)
                                .frame(width: 44, height: 44)
                        }

                        Spacer()

                        Text(controller.durationText)
                            .monospacedDigit()
                            .font(.caption)
                    }
                    .foregroundStyle(.white)
                }
                .padding()
                .background(.black.opacity(0.55))
            }

            if controller.isOpening {
                ProgressView("Opening buffered torrent…")
                    .padding(18)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
            }
        }
        .task {
            let resume = library.position(for: item)
            controller.start(url: url, resumeSeconds: resume)

            while !Task.isCancelled {
                if controller.durationSeconds > 0 {
                    library.updatePlayback(
                        item,
                        position: controller.currentSeconds,
                        duration: controller.durationSeconds
                    )
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
        .onDisappear {
            if controller.durationSeconds > 0 {
                library.updatePlayback(
                    item,
                    position: controller.currentSeconds,
                    duration: controller.durationSeconds
                )
            }
            controller.stop()
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

    func updateUIView(_ uiView: UIView, context: Context) {
        controller.attach(to: uiView)
    }
}

@MainActor
final class VLCTorrentPlayerController: NSObject, ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var isOpening = true
    @Published private(set) var currentMilliseconds: Int = 0
    @Published private(set) var durationMilliseconds: Int = 0

    private let player = VLCMediaPlayer()
    private var pollTask: Task<Void, Never>?
    private var pendingResumeMilliseconds: Int?

    var currentSeconds: Double {
        Double(max(0, currentMilliseconds)) / 1000
    }

    var durationSeconds: Double {
        Double(max(0, durationMilliseconds)) / 1000
    }

    var progress: Double {
        guard durationMilliseconds > 0 else { return 0 }
        return min(max(Double(currentMilliseconds) / Double(durationMilliseconds), 0), 1)
    }

    var currentTimeText: String { Self.format(milliseconds: currentMilliseconds) }
    var durationText: String { Self.format(milliseconds: durationMilliseconds) }

    override init() {
        super.init()
        player.delegate = self
    }

    func attach(to view: UIView) {
        if (player.drawable as? UIView) !== view {
            player.drawable = view
        }
    }

    func start(url: URL, resumeSeconds: Double) {
        stopPolling()
        isOpening = true
        pendingResumeMilliseconds = resumeSeconds > 1
            ? Int(resumeSeconds * 1000)
            : nil

        guard let media = VLCMedia(url: url) else {
            isOpening = false
            return
        }
        media.addOptions([
            "file-caching": 2500,
            "network-caching": 2500
        ])
        player.media = media
        player.play()

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }

                self.currentMilliseconds = max(0, Int(self.player.time.intValue))
                self.durationMilliseconds = max(
                    0,
                    Int(self.player.media?.length.intValue ?? 0)
                )
                self.isPlaying = self.player.isPlaying

                if self.player.state == .playing {
                    self.isOpening = false

                    if let resume = self.pendingResumeMilliseconds,
                       let resumeTime = VLCTime(int: Int32(clamping: resume)) {
                        self.player.time = resumeTime
                        self.pendingResumeMilliseconds = nil
                    }
                }

                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    func togglePlayback() {
        if player.isPlaying {
            player.pause()
        } else {
            player.play()
        }
        isPlaying = player.isPlaying
    }

    func seek(to progress: Double) {
        player.position = min(max(progress, 0), 1)
    }

    func stop() {
        stopPolling()
        player.stop()
        player.media = nil
        isPlaying = false
        isOpening = false
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private static func format(milliseconds: Int) -> String {
        let totalSeconds = max(0, milliseconds / 1000)
        let hours = totalSeconds / 3600
        let minutes = (totalSeconds % 3600) / 60
        let seconds = totalSeconds % 60

        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%02d:%02d", minutes, seconds)
    }
}

extension VLCTorrentPlayerController: VLCMediaPlayerDelegate {
    nonisolated func mediaPlayerStateChanged(_ newState: VLCMediaPlayerState) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.isPlaying = self.player.isPlaying
            if newState == .playing {
                self.isOpening = false
            }
        }
    }

    nonisolated func mediaPlayerTimeChanged(_ aNotification: Notification) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.currentMilliseconds = max(0, Int(self.player.time.intValue))
        }
    }
}
