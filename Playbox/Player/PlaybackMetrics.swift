import Foundation

/// Player events used by torrent diagnostics and device playback measurements.
/// `firstFrame` is a playback-clock proxy, reported when playback time advances.
enum PlaybackMetricEvent: Sendable {
    case opening
    case firstFrame
    case stalled
    case resumed
    case seekRequested(Double)
    case seekReady(Double)
    case failed(String)
    case ended
}
