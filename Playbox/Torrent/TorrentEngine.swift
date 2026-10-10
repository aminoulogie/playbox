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

    private var session: Session?
    private var currentHandle: TorrentHandle?
    private let cacheDirectory: URL

    init() {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheDirectory = root.appendingPathComponent("PlayboxTorrentCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    func play(magnetLink raw: String) async {
        state = .resolving
        do {
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else {
                throw NSError(domain: "TorrentEngine", code: 1, userInfo: [NSLocalizedDescriptionKey: "Empty magnet URL"])
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
            state = .downloading

            let info = try await handle.waitForMetadata(timeout: 60)
            let file = info.files
                .filter { $0.path.lowercased().hasSuffix(".mp4") || $0.path.lowercased().hasSuffix(".mkv") || $0.path.lowercased().hasSuffix(".m4v") || $0.path.lowercased().hasSuffix(".mov") }
                .max { $0.length < $1.length }

            guard let file else {
                state = .failed("No supported video file was found in this torrent")
                return
            }

            var finished = false
            while !finished {
                let status = await handle.status()
                finished = status.progress >= 1.0 || status.state == .seeding
                if !finished {
                    try await Task.sleep(nanoseconds: 1_000_000_000)
                }
            }

            let localURL = cacheDirectory.appendingPathComponent(file.path)
            state = .ready(localURL)
        } catch {
            state = .failed(error.localizedDescription)
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
    }

    deinit {
        Task { await cleanup() }
    }
}
