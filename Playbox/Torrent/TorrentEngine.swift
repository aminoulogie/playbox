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
    @Published private(set) var diagnosticText: String = "Discovery starting…"

    private var session: Session?
    private var currentHandle: TorrentHandle?
    private var dhtDiscoveryTask: Task<Int, Never>?
    private let cacheDirectory: URL

    init() {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheDirectory = root.appendingPathComponent("PlayboxTorrentCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    func play(
        magnetLink raw: String,
        fileIndex: Int? = nil,
        onUpdate: ((EngineState, Double, Int, String) -> Void)? = nil
    ) async {
        await shutdownSession()
        diagnosticText = "Discovery starting…"
        update(.resolving, progress: 0.0, peers: 0, diagnostics: diagnosticText, onUpdate: onUpdate)

        do {
            try Task.checkCancellation()

            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else {
                throw EngineError.message("Empty magnet URL")
            }

            // Use an ephemeral UDP port for DHT so repeated Play/Stop cycles do not
            // collide on a fixed socket. Tracker discovery remains active in parallel.
            let session = Session(settings: SessionSettings(
                listenPort: 6881,
                dhtEnabled: true,
                dhtPort: 0,
                savePath: cacheDirectory.path
            ))
            self.session = session

            try await session.startDHT()

            let params = try AddTorrentParams.fromMagnet(value, savePath: cacheDirectory.path)
            let handle = try await session.addTorrent(params)
            currentHandle = handle

            let infoHash = await handle.infoHash
            dhtDiscoveryTask = Task {
                await session.discoverPeers(for: infoHash)
            }

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
                let diagnostics = await discoveryText(for: handle)
                finished = currentProgress >= 1.0 || status.state == .seeding

                update(
                    .downloading,
                    progress: currentProgress,
                    peers: peers,
                    diagnostics: diagnostics,
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

            let finalDiagnostics = await discoveryText(for: handle)
            await shutdownSession()
            update(.ready(localURL), progress: 1.0, peers: peerCount, diagnostics: finalDiagnostics, onUpdate: onUpdate)
        } catch is CancellationError {
            await shutdownSession()
            update(.idle, progress: 0.0, peers: 0, diagnostics: diagnosticText, onUpdate: onUpdate)
        } catch {
            let finalDiagnostics: String
            if let handle = currentHandle {
                finalDiagnostics = await discoveryText(for: handle)
            } else {
                finalDiagnostics = diagnosticText
            }
            await shutdownSession()
            update(.failed(error.localizedDescription), progress: 0.0, peers: peerCount, diagnostics: finalDiagnostics, onUpdate: onUpdate)
        }
    }

    func cancel() async {
        await shutdownSession()
        state = .idle
        progress = 0.0
        peerCount = 0
        diagnosticText = "Discovery stopped"
    }

    func playableURL() -> URL? {
        if case .ready(let url) = state { return url }
        return nil
    }

    private func waitForFiles(
        handle: TorrentHandle,
        onUpdate: ((EngineState, Double, Int, String) -> Void)?
    ) async throws -> [TorrentInfo.FileEntry] {
        for second in 0..<60 {
            try Task.checkCancellation()

            if let files = await handle.getFiles(), !files.isEmpty {
                return files
            }

            let status = await handle.status()
            let diagnostics = await discoveryText(for: handle)
            update(
                .resolving,
                progress: 0.0,
                peers: status.numPeers,
                diagnostics: diagnostics,
                onUpdate: onUpdate
            )

            if second == 30, status.numPeers == 0 {
                // Continue trying until the full timeout, but surface a more useful
                // state through peerCount instead of appearing frozen.
            }

            try await Task.sleep(for: .seconds(1))
        }

        let diagnostics = await handle.discoveryDiagnostics()
        if diagnostics.connectionAttempts > 0 && diagnostics.connectedPeers == 0 {
            throw EngineError.message(
                "Found peer addresses, but all \(diagnostics.connectionAttempts) connection attempts failed."
            )
        }
        if diagnostics.trackerPeers == 0 && diagnostics.dhtPeers == 0 {
            throw EngineError.message(
                "Trackers and DHT returned no peer addresses for this info hash."
            )
        }
        throw EngineError.message(
            "Connected to \(diagnostics.connectedPeers) peer(s), but torrent metadata did not arrive within 60 seconds."
        )
    }

    private func shutdownSession() async {
        dhtDiscoveryTask?.cancel()
        dhtDiscoveryTask = nil

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

    private func discoveryText(for handle: TorrentHandle) async -> String {
        let d = await handle.discoveryDiagnostics()
        return "Tracker: \(d.trackerPeers) peers (\(d.trackerSeeders)S/\(d.trackerLeechers)L, \(d.trackerFailures) failures) · DHT: \(d.dhtPeers) peers/\(d.dhtNodes) nodes · Attempts: \(d.connectionAttempts) · Connected: \(d.connectedPeers) · Failed: \(d.connectionFailures)"
    }

    private func update(
        _ nextState: EngineState,
        progress nextProgress: Double,
        peers: Int,
        diagnostics: String,
        onUpdate: ((EngineState, Double, Int, String) -> Void)?
    ) {
        state = nextState
        progress = nextProgress
        peerCount = peers
        diagnosticText = diagnostics
        onUpdate?(nextState, nextProgress, peers, diagnostics)
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
