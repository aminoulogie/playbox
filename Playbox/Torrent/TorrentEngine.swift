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
        onUpdate: ((EngineState, Double) -> Void)? = nil
    ) async {
        update(.resolving, progress: 0.0, onUpdate: onUpdate)

        do {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else {
                throw NSError(
                    domain: "TorrentEngine",
                    code: 1,
                    userInfo: [NSLocalizedDescriptionKey: "Empty magnet URL"]
                )
            }

            let session = Session(settings: SessionSettings(
                listenPort: 6881,
                dhtEnabled: true,
                savePath: cacheDirectory.path
            ))
            self.session = session

            try await session.startDHT()

            let params = try AddTorrentParams.fromMagnet(value, savePath: cacheDirectory.path)
            let handle = try await session.addTorrent(params)
            currentHandle = handle

            try await handle.start()
            update(.downloading, progress: 0.0, onUpdate: onUpdate)

            let info = try await handle.waitForMetadata(timeout: 60)
            let file = selectVideoFile(from: info.files, preferredIndex: fileIndex)

            guard let file else {
                update(
                    .failed("No supported video file was found in this torrent"),
                    progress: 0.0,
                    onUpdate: onUpdate
                )
                return
            }

            var finished = false
            while !finished {
                let status = await handle.status()
                let currentProgress = max(0, min(status.progress, 1.0))
                finished = currentProgress >= 1.0 || status.state == .seeding

                update(
                    .downloading,
                    progress: currentProgress,
                    onUpdate: onUpdate
                )

                if !finished {
                    try await Task.sleep(for: .seconds(1))
                }
            }

            let localURL = cacheDirectory.appendingPathComponent(file.path)
            guard FileManager.default.fileExists(atPath: localURL.path) else {
                update(
                    .failed("The torrent finished, but the selected video file is missing from the cache"),
                    progress: 0.0,
                    onUpdate: onUpdate
                )
                return
            }

            update(.ready(localURL), progress: 1.0, onUpdate: onUpdate)
        } catch {
            update(.failed(error.localizedDescription), progress: 0.0, onUpdate: onUpdate)
        }
    }

    func playableURL() -> URL? {
        if case .ready(let url) = state { return url }
        return nil
    }

    func cleanup() async {
        if let handle = currentHandle {
            await session?.removeTorrent(await handle.infoHash, deleteFiles: false)
        }
        if let session = session {
            try? await session.shutdown()
        }
        currentHandle = nil
        session = nil
        progress = 0.0
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
        onUpdate: ((EngineState, Double) -> Void)?
    ) {
        state = nextState
        progress = nextProgress
        onUpdate?(nextState, nextProgress)
    }

    deinit {
        Task { await cleanup() }
    }
}
