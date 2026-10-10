import Foundation

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
    @Published private(set) var diagnosticText: String = "libtorrent starting…"

    private var session: (any LibtorrentSession)?
    private var currentJobID: UUID?
    private var selectedFileIndex: Int?
    private let cacheDirectory: URL

    init() {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        cacheDirectory = root.appendingPathComponent("PlayboxLibtorrentCache", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: cacheDirectory,
            withIntermediateDirectories: true
        )
    }

    func play(
        magnetLink raw: String,
        fileIndex: Int? = nil,
        onUpdate: ((EngineState, Double, Int, String) -> Void)? = nil
    ) async {
        await stopCurrentJob()

        let magnet = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !magnet.isEmpty else {
            update(
                .failed("Empty magnet URL"),
                progress: 0,
                peers: 0,
                diagnostics: "libtorrent did not receive a magnet URL",
                onUpdate: onUpdate
            )
            return
        }

        let nativeSession = LibtorrentSessionFactory.makeDefault()
        let jobID = UUID()

        session = nativeSession
        currentJobID = jobID
        selectedFileIndex = fileIndex

        update(
            .resolving,
            progress: 0,
            peers: 0,
            diagnostics: "libtorrent starting tracker, DHT and peer discovery…",
            onUpdate: onUpdate
        )

        let input = LibtorrentJobInput(
            jobId: jobID,
            magnetUri: magnet,
            downloadDirectory: cacheDirectory
        )

        let initialSelection: LibtorrentFileSelection?
        if let fileIndex {
            initialSelection = LibtorrentFileSelection(
                fileIndexes: [fileIndex],
                primaryFileIndex: fileIndex,
                priorityFileIndexes: [fileIndex]
            )
        } else {
            initialSelection = nil
        }

        do {
            let events = AsyncThrowingStream<LibtorrentEvent, Error> { continuation in
                Task {
                    do {
                        try await nativeSession.start(
                            input: input,
                            selection: initialSelection
                        ) { event in
                            continuation.yield(event)
                        }
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }

            try await withTaskCancellationHandler {
                var metadataWaitTicks = 0

                for try await event in events {
                    try Task.checkCancellation()

                    switch event {
                    case .progress(let snapshot):
                        let hasMetadata = !snapshot.files.isEmpty

                        if hasMetadata {
                            metadataWaitTicks = 0
                            try await ensureValidFileSelection(
                                snapshot: snapshot,
                                session: nativeSession,
                                jobID: jobID
                            )
                        } else {
                            metadataWaitTicks += 1

                            if metadataWaitTicks % 15 == 0 {
                                try? await nativeSession.reannounce(jobId: jobID)
                                try? await nativeSession.refreshPeers(jobId: jobID)
                            }

                            if metadataWaitTicks >= 120 {
                                throw EngineError.message(
                                    "libtorrent could not obtain torrent metadata after 120 seconds. " +
                                    diagnostics(for: snapshot)
                                )
                            }
                        }

                        publish(
                            snapshot,
                            resolving: !hasMetadata,
                            onUpdate: onUpdate
                        )

                    case .completed(let snapshot):
                        try await ensureValidFileSelection(
                            snapshot: snapshot,
                            session: nativeSession,
                            jobID: jobID
                        )

                        guard let file = selectedVideoFile(in: snapshot.files) else {
                            throw EngineError.message(
                                "libtorrent completed the selected data, but no supported video file was found."
                            )
                        }

                        let localURL = cacheDirectory.appendingPathComponent(file.path)
                        guard FileManager.default.fileExists(atPath: localURL.path) else {
                            throw EngineError.message(
                                "libtorrent finished the selected file, but it is missing from the cache."
                            )
                        }

                        let finalDiagnostics = diagnostics(for: snapshot)
                        try? await nativeSession.cancel(jobId: jobID)
                        clearJobReferences()

                        update(
                            .ready(localURL),
                            progress: 1,
                            peers: snapshot.peerCount ?? 0,
                            diagnostics: finalDiagnostics,
                            onUpdate: onUpdate
                        )
                        return

                    case .streamReady:
                        // The current native bridge does not emit this event yet.
                        // Keep the API forward-compatible without marking a partial
                        // file as ready for the Download button.
                        break
                    }
                }

                throw EngineError.message("The libtorrent event stream ended unexpectedly.")
            } onCancel: {
                Task {
                    try? await nativeSession.cancel(jobId: jobID)
                }
            }
        } catch is CancellationError {
            try? await nativeSession.cancel(jobId: jobID)
            clearJobReferences()
            update(
                .idle,
                progress: 0,
                peers: 0,
                diagnostics: "libtorrent operation cancelled",
                onUpdate: onUpdate
            )
        } catch {
            try? await nativeSession.cancel(jobId: jobID)
            let message = error.localizedDescription
            clearJobReferences()
            update(
                .failed(message),
                progress: progress,
                peers: peerCount,
                diagnostics: diagnosticText,
                onUpdate: onUpdate
            )
        }
    }

    func cancel() async {
        await stopCurrentJob()
        state = .idle
        progress = 0
        peerCount = 0
        diagnosticText = "libtorrent stopped"
    }

    func playableURL() -> URL? {
        if case .ready(let url) = state {
            return url
        }
        return nil
    }

    private func ensureValidFileSelection(
        snapshot: LibtorrentProgress,
        session: any LibtorrentSession,
        jobID: UUID
    ) async throws {
        guard !snapshot.files.isEmpty else { return }

        if let selectedFileIndex,
           let selected = snapshot.files.first(where: { $0.id == selectedFileIndex }),
           Self.isSupportedVideo(selected.path) {
            return
        }

        guard let fallback = snapshot.files
            .filter({ Self.isSupportedVideo($0.path) })
            .max(by: { ($0.sizeBytes ?? 0) < ($1.sizeBytes ?? 0) })
        else {
            throw EngineError.message("No supported video file was found in this torrent.")
        }

        selectedFileIndex = fallback.id
        try await session.applySelection(
            jobId: jobID,
            selection: LibtorrentFileSelection(
                fileIndexes: [fallback.id],
                primaryFileIndex: fallback.id,
                priorityFileIndexes: [fallback.id]
            )
        )
    }

    private func selectedVideoFile(in files: [LibtorrentFileInfo]) -> LibtorrentFileInfo? {
        if let selectedFileIndex,
           let selected = files.first(where: { $0.id == selectedFileIndex }),
           Self.isSupportedVideo(selected.path) {
            return selected
        }

        return files
            .filter { Self.isSupportedVideo($0.path) }
            .max { ($0.sizeBytes ?? 0) < ($1.sizeBytes ?? 0) }
    }

    private func publish(
        _ snapshot: LibtorrentProgress,
        resolving: Bool,
        onUpdate: ((EngineState, Double, Int, String) -> Void)?
    ) {
        let fileProgress: Double?
        if let file = selectedVideoFile(in: snapshot.files),
           let percent = file.percentComplete {
            fileProgress = percent / 100.0
        } else if let percent = snapshot.percentComplete {
            fileProgress = percent / 100.0
        } else {
            fileProgress = nil
        }

        let normalizedProgress = max(0, min(fileProgress ?? 0, 1))
        let peers = snapshot.peerCount
            ?? snapshot.swarmDiagnostics?.connectedPeers
            ?? 0

        update(
            resolving ? .resolving : .downloading,
            progress: normalizedProgress,
            peers: peers,
            diagnostics: diagnostics(for: snapshot),
            onUpdate: onUpdate
        )
    }

    private func diagnostics(for snapshot: LibtorrentProgress) -> String {
        guard let swarm = snapshot.swarmDiagnostics else {
            return "libtorrent · peers \(snapshot.peerCount ?? 0)"
        }

        let trackers = swarm.trackers
        let trackerFailures = trackers.filter {
            ($0.consecutiveFailures ?? 0) > 0 || $0.lastEvent == "error"
        }.count
        let trackerReplies = trackers.compactMap(\.lastResponsePeerCount).reduce(0, +)

        let connected = swarm.connectedPeers ?? snapshot.peerCount ?? 0
        let known = swarm.knownPeers ?? 0
        let candidates = swarm.connectCandidates ?? 0
        let dhtNodes = swarm.dht?.nodeCount ?? 0
        let dhtPeers = swarm.dht?.lastReplyPeerCount ?? 0
        let speed = snapshot.bytesPerSecond ?? 0

        return "libtorrent · Connected: \(connected) · Known: \(known) · Candidates: \(candidates) · " +
            "Trackers: \(trackers.count) (\(trackerFailures) failing, \(trackerReplies) peers last replies) · " +
            "DHT: \(dhtNodes) nodes/\(dhtPeers) peers · \(Self.formatSpeed(speed))"
    }

    private func stopCurrentJob() async {
        if let session, let currentJobID {
            try? await session.cancel(jobId: currentJobID)
        }
        clearJobReferences()
    }

    private func clearJobReferences() {
        currentJobID = nil
        selectedFileIndex = nil
        session = nil
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

    private static func isSupportedVideo(_ path: String) -> Bool {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "mp4", "m4v", "mov", "mkv":
            true
        default:
            false
        }
    }

    private static func formatSpeed(_ bytesPerSecond: Double) -> String {
        guard bytesPerSecond > 0 else { return "0 B/s" }

        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.includesUnit = true
        formatter.isAdaptive = true
        return formatter.string(fromByteCount: Int64(bytesPerSecond)) + "/s"
    }

    private enum EngineError: LocalizedError {
        case message(String)

        var errorDescription: String? {
            switch self {
            case .message(let message):
                message
            }
        }
    }
}
