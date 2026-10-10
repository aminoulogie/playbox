import SwiftUI
import AVKit

struct TrackedPlayerView: View {
    let url: URL
    let item: MetaPreview
    @EnvironmentObject private var library: LibraryStore
    @State private var player = AVPlayer()
    @State private var observer: Any?
    @State private var errorMessage: String?
    @State private var isLoading = true

    var body: some View {
        ZStack {
            VideoPlayer(player: player).ignoresSafeArea()
            if isLoading && errorMessage == nil { ProgressView().controlSize(.large) }
            if let errorMessage {
                ContentUnavailableView("Playback failed", systemImage: "exclamationmark.triangle", description: Text(errorMessage))
                    .padding().background(.ultraThinMaterial)
            }
        }
        .task { await startPlayback() }
        .onDisappear { stopPlayback() }
    }

    @MainActor
    private func startPlayback() async {
        errorMessage = nil
        isLoading = true
        let asset = AVURLAsset(url: url)
        do {
            let playable = try await asset.load(.isPlayable)
            guard playable else { throw PlayerError.notPlayable }
            let playerItem = AVPlayerItem(asset: asset)
            player.replaceCurrentItem(with: playerItem)
            let resume = library.position(for: item)
            if resume > 0 {
                await player.seek(to: CMTime(seconds: resume, preferredTimescale: 600))
            }
            observer = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 2, preferredTimescale: 600), queue: .main) { time in
                Task { @MainActor in
                    let duration = CMTimeGetSeconds(player.currentItem?.duration ?? .invalid)
                    library.updatePlayback(item, position: CMTimeGetSeconds(time), duration: duration)
                }
            }
            player.play()
            isLoading = false
        } catch {
            isLoading = false
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func stopPlayback() {
        player.pause()
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
        player.replaceCurrentItem(with: nil)
    }
}

private enum PlayerError: LocalizedError {
    case notPlayable
    var errorDescription: String? { "This direct stream is not playable by the iOS media engine." }
}
