import SwiftUI
import UIKit
import MediaPlayer
import AVFoundation

@MainActor
final class PlaybackGestureController: ObservableObject {
    enum Mode {
        case brightness
        case volume
    }

    @Published private(set) var hudSymbol: String?
    @Published private(set) var hudText: String?

    private weak var volumeSlider: UISlider?
    private var mode: Mode?
    private var startValue: Double = 0
    private var hideTask: Task<Void, Never>?

    func install(volumeView: MPVolumeView) {
        volumeSlider = volumeView.subviews.compactMap { $0 as? UISlider }.first
    }

    func update(startX: CGFloat, translation: CGSize, width: CGFloat) {
        if mode == nil {
            guard abs(translation.height) > abs(translation.width),
                  abs(translation.height) > 6 else { return }

            if startX < width / 2 {
                mode = .brightness
                startValue = Double(UIScreen.main.brightness)
            } else {
                mode = .volume
                startValue = Double(volumeSlider?.value ?? AVAudioSession.sharedInstance().outputVolume)
            }
        }

        guard let mode else { return }
        let delta = -Double(translation.height) / 260.0
        let next = min(max(startValue + delta, 0), 1)

        switch mode {
        case .brightness:
            UIScreen.main.brightness = CGFloat(next)
            hudSymbol = "sun.max.fill"
        case .volume:
            volumeSlider?.setValue(Float(next), animated: false)
            volumeSlider?.sendActions(for: .valueChanged)
            hudSymbol = next == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill"
        }

        hudText = String(format: "%.0f%%", next * 100)
        hideTask?.cancel()
    }

    func end() {
        mode = nil
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            self?.hudSymbol = nil
            self?.hudText = nil
        }
    }
}

struct SystemVolumeHost: UIViewRepresentable {
    @ObservedObject var controller: PlaybackGestureController

    func makeUIView(context: Context) -> MPVolumeView {
        let view = MPVolumeView(frame: .zero)
        view.showsRouteButton = false
        controller.install(volumeView: view)
        return view
    }

    func updateUIView(_ uiView: MPVolumeView, context: Context) {
        controller.install(volumeView: uiView)
    }
}

struct PlaybackGestureHUD: View {
    @ObservedObject var controller: PlaybackGestureController

    var body: some View {
        if let symbol = controller.hudSymbol,
           let text = controller.hudText {
            VStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 28, weight: .semibold))
                Text(text)
                    .font(.headline)
                    .monospacedDigit()
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 24)
            .padding(.vertical, 18)
            .background(.black.opacity(0.72), in: RoundedRectangle(cornerRadius: 16))
            .transition(.opacity)
        }
    }
}
