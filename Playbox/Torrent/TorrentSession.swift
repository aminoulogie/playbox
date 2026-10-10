import Foundation

@MainActor
final class TorrentSession: ObservableObject {
    enum State: Equatable { case idle, preparing, ready, failed(String) }

    @Published private(set) var state: State = .idle
    @Published private(set) var magnet: MagnetLink?
    let cacheDirectory: URL

    init() {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheDirectory = root.appendingPathComponent("PlayboxTorrentCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }

    func prepare(magnet raw: String) {
        state = .preparing
        do {
            let parsed = try MagnetLink(raw)
            magnet = parsed
            let directory = cacheDirectory.appendingPathComponent(parsed.infoHash, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            state = .ready
        } catch {
            magnet = nil
            state = .failed(error.localizedDescription)
        }
    }

    func clearCache() throws {
        if FileManager.default.fileExists(atPath: cacheDirectory.path) {
            try FileManager.default.removeItem(at: cacheDirectory)
        }
        try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
    }
}
