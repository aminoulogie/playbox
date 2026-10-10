import SwiftUI
import UIKit
import VLCKitSPM

@MainActor
final class VLCPlaybackController: ObservableObject {
    @Published private(set) var isPlaying = false

    fileprivate let player = VLCMediaPlayer()

    func attach(to view: UIView, url: URL) {
        player.drawable = view
        player.media = VLCMedia(url: url)
        player.play()
        isPlaying = true
    }

    func togglePlayback() {
        if player.isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    func stop() {
        player.stop()
        player.drawable = nil
        isPlaying = false
    }
}

struct VLCVideoSurface: UIViewRepresentable {
    let url: URL
    @ObservedObject var controller: VLCPlaybackController

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .black
        controller.attach(to: view, url: url)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        controller.player.drawable = uiView
    }
}

struct VLCLocalPlayerView: View {
    let url: URL
    let item: MetaPreview

    @StateObject private var controller = VLCPlaybackController()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VLCVideoSurface(url: url, controller: controller)
                .ignoresSafeArea()

            VStack {
                Spacer()

                HStack(spacing: 20) {
                    Button {
                        controller.togglePlayback()
                    } label: {
                        Image(systemName: controller.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 24, weight: .semibold))
                            .frame(width: 56, height: 56)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.white)
                }
                .padding(.bottom, 28)
            }
        }
        .onDisappear {
            controller.stop()
        }
    }
}
