import SwiftUI
import AVKit

struct TrackedPlayerView: View {
    let url: URL
    let item: MetaPreview
    @EnvironmentObject private var library: LibraryStore
    @State private var player = AVPlayer()
    @State private var observer: Any?
    @State private var resumed = false

    var body: some View {
        VideoPlayer(player: player)
            .ignoresSafeArea()
            .onAppear {
                player.replaceCurrentItem(with: AVPlayerItem(url: url))
                let resume = library.position(for: item)
                if resume > 0 {
                    player.seek(to: CMTime(seconds: resume, preferredTimescale: 600))
                }
                observer = player.addPeriodicTimeObserver(
                    forInterval: CMTime(seconds: 2, preferredTimescale: 600),
                    queue: .main
                ) { time in
                    guard let duration = player.currentItem?.duration else { return }
                    library.updatePlayback(
                        item,
                        position: CMTimeGetSeconds(time),
                        duration: CMTimeGetSeconds(duration)
                    )
                }
                player.play()
            }
            .onDisappear {
                player.pause()
                if let observer { player.removeTimeObserver(observer) }
                observer = nil
                player.replaceCurrentItem(with: nil)
            }
    }
}
