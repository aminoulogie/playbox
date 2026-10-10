import Foundation
import SwiftTorrent

@MainActor
final class TorrentEngine: ObservableObject {
    enum EngineState: Equatable {
        case idle
        case resolving
        case downloading
        case ready(URL)
        case failed(String)
    }

    @Published private(set) var state: EngineState = .idle
    @Published private(set) var progress: Double = 0.0
    @Published private(set) var peerCount: Int = 0

    private var session: Session?
    private var currentHandle: TorrentHandle?
    private let cacheDirectory: URL

    init() {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheDirectory = root.appendingPathComponent("PlayboxTorrentCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    func play(
        magnetLink raw: String,
        fileIndex: Int? = nil,
        onUpdate: ((EngineState, Double, Int) -> Void)? = nil
    ) async {
        await shutdownSession()
        update(.resolving, progress: 0.0, peers: 0, onUpdate: onUpdate)

        do {
            try Task.checkCancellation()

            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else {
                throw EngineError.message("Empty magnet URL")
            }

            // SwiftTorrent's current DHT node is not connected to TorrentHandle peer
            // discovery. Disable it here to avoid binding a second fixed UDP port;
            // tracker URLs from the Stremio stream are the active peer source.
            let session = Session(settings: SessionSettings(
                listenPort: 6881,
                dhtEnabled: false,
                savePath: cacheDirectory.path
            ))
            self.session = session

            let params = try AddTorrentParams.fromMagnet(value, savePath: cacheDirectory.path)
            let handle = try await session.addTorrent(params)
            currentHandle = handle

            try await handle.start()

            let files = try await waitForFiles(handle: handle, onUpdate: onUpdate)
            try Task.checkCancellation()

            guard let file = selectVideoFile(from: files, preferredIndex: fileIndex) else {
                throw EngineError.message("No supported video file was found in this torrent")
            }

            var finished = false
            while !finished {
                try Task.checkCancellation()

                let status = await handle.status()
                let currentProgress = max(0, min(status.progress, 1.0))
                let peers = status.numPeers
                finished = currentProgress >= 1.0 || status.state == .seeding

                update(
                    .downloading,
                    progress: currentProgress,
                    peers: peers,
                    onUpdate: onUpdate
                )

                if !finished {
                    try await Task.sleep(for: .seconds(1))
                }
            }

            let localURL = cacheDirectory.appendingPathComponent(file.path)
            guard FileManager.default.fileExists(atPath: localURL.path) else {
                throw EngineError.message(
                    "The torrent finished, but the selected video file is missing from the cache"
                )
            }

            await shutdownSession()
            update(.ready(localURL), progress: 1.0, peers: peerCount, onUpdate: onUpdate)
        } catch is CancellationError {
            await shutdownSession()
            update(.idle, progress: 0.0, peers: 0, onUpdate: onUpdate)
        } catch {
            await shutdownSession()
            update(.failed(error.localizedDescription), progress: 0.0, peers: 0, onUpdate: onUpdate)
        }
    }

    func cancel() async {
        await shutdownSession()
        state = .idle
        progress = 0.0
        peerCount = 0
    }

    func playableURL() -> URL? {
        if case .ready(let url) = state { return url }
        return nil
    }

    private func waitForFiles(
        handle: TorrentHandle,
        onUpdate: ((EngineState, Double, Int) -> Void)?
    ) async throws -> [TorrentInfo.FileEntry] {
        for second in 0..<60 {
            try Task.checkCancellation()

            if let files = await handle.getFiles(), !files.isEmpty {
                return files
            }

            let status = await handle.status()
            update(.resolving, progress: 0.0, peers: status.numPeers, onUpdate: onUpdate)

            if second == 30, status.numPeers == 0 {
                // Continue trying until the full timeout, but surface a more useful
                // state through peerCount instead of appearing frozen.
            }

            try await Task.sleep(for: .seconds(1))
        }

        throw EngineError.message(
            peerCount == 0
                ? "No peers returned metadata. Check that this torrent has working tracker sources."
                : "Connected to peers, but torrent metadata did not arrive within 60 seconds."
        )
    }

    private func shutdownSession() async {
        if let handle = currentHandle, let session {
            await session.removeTorrent(await handle.infoHash, deleteFiles: false)
        }
        if let session {
            try? await session.shutdown()
        }
        currentHandle = nil
        self.session = nil
    }

    private func selectVideoFile(
        from files: [TorrentInfo.FileEntry],
        preferredIndex: Int?
    ) -> TorrentInfo.FileEntry? {
        if let preferredIndex,
           files.indices.contains(preferredIndex) {
            let preferred = files[preferredIndex]
            if Self.isSupportedVideo(preferred.path) {
                return preferred
            }
        }

        return files
            .filter { Self.isSupportedVideo($0.path) }
            .max { $0.length < $1.length }
    }

    private static func isSupportedVideo(_ path: String) -> Bool {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "mp4", "m4v", "mov", "mkv":
            return true
        default:
            return false
        }
    }

    private func update(
        _ nextState: EngineState,
        progress nextProgress: Double,
        peers: Int,
        onUpdate: ((EngineState, Double, Int) -> Void)?
    ) {
        state = nextState
        progress = nextProgress
        peerCount = peers
        onUpdate?(nextState, nextProgress, peers)
    }

    private enum EngineError: LocalizedError {
        case message(String)

        var errorDescription: String? {
            switch self {
            case .message(let message):
                return message
            }
        }
    }
}
