import Foundation

/// Fetches torrent metadata and connects peers for the most likely source
/// while the user is still on the detail page. No file data is downloaded.
/// When Play starts the same torrent, the native session adopts the warm
/// handle, so playback skips metadata discovery and peer connection.
@MainActor
final class TorrentPrewarmer {
    static let shared = TorrentPrewarmer()

    private var jobID: UUID?
    private var magnet: String?

    private let cacheDirectory = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("PlayboxLibtorrentCache", isDirectory: true)

    func prewarm(magnet raw: String) {
        let magnet = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !magnet.isEmpty, magnet != self.magnet else { return }
        cancel()

        let id = UUID()
        jobID = id
        self.magnet = magnet
        let input = LibtorrentJobInput(
            jobId: id,
            magnetUri: magnet,
            downloadDirectory: cacheDirectory,
            prewarm: true
        )
        Task.detached(priority: .utility) {
            try? await LibtorrentSessionFactory.shared.start(
                input: input,
                selection: nil
            ) { _ in }
        }
    }

    func cancel() {
        guard let id = jobID else { return }
        jobID = nil
        magnet = nil
        // A no-op when Play already adopted this torrent.
        Task.detached(priority: .utility) {
            try? await LibtorrentSessionFactory.shared.cancel(jobId: id)
        }
    }

    /// Creates the shared session early so the DHT bootstraps during browsing.
    nonisolated static func warmUpSession() {
        Task.detached(priority: .background) {
            _ = LibtorrentSessionFactory.shared
        }
    }
}
