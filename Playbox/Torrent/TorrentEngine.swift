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
    
    func play(magnetLink: String) async {
        state = .resolving
        do {
            let session = Session(settings: SessionSettings(
                listenPort: 6881,
                dhtEnabled: true,
                savePath: cacheDirectory.path
            ))
            self.session = session
            
            // Start DHT for metadata resolution
            try await session.startDHT()
            
            // Add torrent from magnet link
            let params = try AddTorrentParams.fromMagnet(magnetLink, savePath: cacheDirectory.path)
            let handle = try await session.addTorrent(params)
            self.currentHandle = handle
            
            // Start download
            try await handle.start()
            
            state = .downloading
            
            // Wait for metadata
            let info = try await handle.waitForMetadata(timeout: 60)
            
            // Find best video file
            let videoFile = info.files.filter { $0.path.lowercased().hasSuffix(".mp4") || 
                                                 $0.path.lowercased().hasSuffix(".mkv") ||
                                                 $0.path.lowercased().hasSuffix(".m4v") ||
                                                 $0.path.lowercased().hasSuffix(".mov") }
                .max { $0.length < $1.length }
            
            guard let videoFile = videoFile else {
                state = .failed("No video file found in torrent")
                return
            }
            
            // Construct local file path
            let fileURL = cacheDirectory.appendingPathComponent(info.name).appendingPathComponent(videoFile.path)
            
            // Start download
            state = .downloading
            try await handle.start()
            
            // Monitor download progress
            var allPiecesDownloaded = false
            while !allPiecesDownloaded {
                let status = await handle.status()
                allPiecesDownloaded = status.isFinished
                
                if !allPiecesDownloaded {
                    try await Task.sleep(nanoseconds: 1_000_000_000) // 1 second
                }
            }
            
            // File ready
            state = .ready(fileURL)
            
        } catch {
            state = .failed(error.localizedDescription)
        }
    }
    
    func getPlayableURL() -> URL? {
        if case .ready(let url) = state {
            return url
        }
        return nil
    }
    
    func cleanup() async {
        if let handle = currentHandle {
            await session?.removeTorrent(await handle.infoHash, deleteFiles: false)
        }
        if let session = session {
            try? await session.shutdown()
        }
    }
    
    deinit {
        Task {
            await cleanup()
        }
    }
}
