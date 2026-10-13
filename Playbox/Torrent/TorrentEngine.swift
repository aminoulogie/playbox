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
    @Published private(set) var downloadSpeed: Double = 0
    /// Bytes of the selected video file already on disk.
    @Published private(set) var downloadedBytes: Int64 = 0
    @Published private(set) var cacheProgress: Double = 0
    @Published private(set) var bufferedBytes: Int64 = 0
    @Published private(set) var bufferTargetBytes: Int64 = 0
    @Published private(set) var diagnosticText: String = "libtorrent starting…"

    @Published private(set) var bufferedProgress: Double?
    @Published private(set) var seekBufferProgress: Double = 0
    @Published private(set) var isSeeking = false
    @Published private(set) var seekError: String?
    @Published private(set) var metadataSeconds: Double?
    @Published private(set) var bufferReadySeconds: Double?
    @Published private(set) var playbackBeganSeconds: Double?
    @Published private(set) var rebufferCount = 0
    @Published private(set) var rebufferSeconds: Double = 0

    private var operationStartedAt: Date?
    private var stallStartedAt: Date?
    private var streamingURL: URL?
    private var completedFile = false
    private var selectedFileSize: Int64 = 0
    private var nativePlaybackPosition: Double?
    private var nativePlaybackBufferedBytes: Int64 = 0
    private var nativePlaybackBufferTargetBytes: Int64 = 0
    private var seekRequestID: UUID?
    private var positionUpdateTask: Task<Void, Never>?
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
        streaming: Bool = true,
        onUpdate: ((EngineState, Double, Int, Double, Double, String) -> Void)? = nil
    ) async {
        await stopCurrentJob()
        resetPlaybackMeasurements()

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

        // The shared session keeps DHT and peers warm, and adopts a torrent
        // prewarmed from the detail page.
        let nativeSession = LibtorrentSessionFactory.shared
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
                let metadataStartedAt = Date()
                var lastDiscoveryRefreshAt = metadataStartedAt

                for try await event in events {
                    try Task.checkCancellation()
                    guard currentJobID == jobID else { return }

                    switch event {
                    case .progress(let snapshot):
                        let hasMetadata = !snapshot.files.isEmpty

                        if hasMetadata {
                            if metadataSeconds == nil {
                                metadataSeconds = Date().timeIntervalSince(metadataStartedAt)
                            }
                            try await ensureValidFileSelection(
                                snapshot: snapshot,
                                session: nativeSession,
                                jobID: jobID
                            )
                        } else {
                            let now = Date()
                            if now.timeIntervalSince(lastDiscoveryRefreshAt) >= 6 {
                                lastDiscoveryRefreshAt = now
                                try? await nativeSession.reannounce(jobId: jobID)
                                try? await nativeSession.refreshPeers(jobId: jobID)
                            }

                            if now.timeIntervalSince(metadataStartedAt) >= 120 {
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

                        completedFile = true
                        bufferedProgress = 1
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

                    case .streamReady(let readiness):
                        guard streaming else { continue }
                        selectedFileIndex = readiness.primaryFileIndex
                        streamingURL = readiness.fileURL
                        if bufferReadySeconds == nil, let started = operationStartedAt {
                            bufferReadySeconds = Date().timeIntervalSince(started)
                        }
                        update(
                            .ready(readiness.fileURL),
                            progress: progress,
                            peers: peerCount,
                            speed: downloadSpeed,
                            cacheProgress: 1,
                            diagnostics: "Streaming buffer ready · \(Self.formatBytes(readiness.bytesAvailable)) buffered",
                            onUpdate: onUpdate
                        )
                        // Do not return. libtorrent must keep downloading while
                        // the VLC player reads the growing local file.
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
            guard currentJobID == jobID else { return }
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
            guard currentJobID == jobID else { return }
            let message = error.localizedDescription
            seekError = message
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
        downloadSpeed = 0
        downloadedBytes = 0
        cacheProgress = 0
        bufferedBytes = 0
        bufferTargetBytes = 0
        diagnosticText = "libtorrent stopped"
    }

    func playableURL() -> URL? {
        if case .ready(let url) = state {
            return url
        }
        return nil
    }

    /// Follow the playback clock without disturbing an in-flight seek.
    func reportPlaybackPosition(seconds: Double, duration: Double) {
        guard !isSeeking, seconds.isFinite, duration.isFinite, duration > 0,
              let session, let jobID = currentJobID else { return }
        let position = min(max(seconds / duration, 0), 0.999999)
        positionUpdateTask?.cancel()
        positionUpdateTask = Task {
            guard !Task.isCancelled, currentJobID == jobID else { return }
            do {
                try await session.updatePlaybackPosition(jobId: jobID, progress: position)
            } catch {
                guard currentJobID == jobID, !Task.isCancelled else { return }
                seekError = "Could not update the playback buffer: " + error.localizedDescription
            }
        }
    }

    /// VLC uses time fractions; the native bridge estimates the file byte range.
    /// Wait for contiguous verified pieces around that range before applying a seek.
    func prepareSeek(to progress: Double) async -> Bool {
        guard progress.isFinite else { return false }
        if completedFile { return true }
        guard let session, let jobID = currentJobID else { return false }

        let requested = min(max(progress, 0), 0.999999)
        let requestID = UUID()
        seekRequestID = requestID
        isSeeking = true
        seekError = nil
        seekBufferProgress = 0
        let previousPositionUpdate = positionUpdateTask
        previousPositionUpdate?.cancel()
        defer {
            if seekRequestID == requestID {
                isSeeking = false
                seekRequestID = nil
            }
        }

        do {
            await previousPositionUpdate?.value
            try Task.checkCancellation()
            guard currentJobID == jobID, seekRequestID == requestID else { return completedFile }
            try await session.updatePlaybackPosition(jobId: jobID, progress: requested)
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline {
                try Task.checkCancellation()
                guard currentJobID == jobID, seekRequestID == requestID else { return completedFile }
                if let reported = nativePlaybackPosition,
                   abs(reported - requested) < 0.000001,
                   nativePlaybackBufferTargetBytes > 0 {
                    seekBufferProgress = min(
                        Double(nativePlaybackBufferedBytes) / Double(nativePlaybackBufferTargetBytes),
                        1
                    )
                    if nativePlaybackBufferedBytes >= nativePlaybackBufferTargetBytes {
                        return true
                    }
                }
                try await Task.sleep(for: .milliseconds(150))
            }
            seekError = "The selected position is still buffering. Try again or choose another source."
        } catch is CancellationError {
            return false
        } catch {
            guard currentJobID == jobID, seekRequestID == requestID else { return false }
            seekError = "Could not prepare this position: " + error.localizedDescription
        }
        return false
    }

    func recordPlaybackEvent(_ event: PlaybackMetricEvent) {
        switch event {
        case .firstFrame:
            if playbackBeganSeconds == nil, let started = operationStartedAt {
                playbackBeganSeconds = Date().timeIntervalSince(started)
                UserDefaults.standard.set(playbackBeganSeconds, forKey: "playbox.playback.lastStartupSeconds")
                UserDefaults.standard.set(metadataSeconds, forKey: "playbox.playback.lastMetadataSeconds")
                UserDefaults.standard.set(bufferReadySeconds, forKey: "playbox.playback.lastBufferSeconds")
            }
        case .stalled:
            if stallStartedAt == nil {
                stallStartedAt = Date()
                rebufferCount += 1
            }
        case .resumed, .ended, .paused:
            finishStall()
        case .failed(let message):
            finishStall()
            seekError = message
        case .opening:
            seekError = nil
            finishStall()
        case .seekRequested:
            finishStall()
        case .seekReady:
            break
        }
    }

    var playbackDiagnostics: String {
        var lines: [String] = []
        if let value = metadataSeconds { lines.append(String(format: "Metadata ready: %.2f s", value)) }
        if let value = bufferReadySeconds { lines.append(String(format: "Startup buffer ready: %.2f s", value)) }
        if let value = playbackBeganSeconds { lines.append(String(format: "Playback began: %.2f s", value)) }
        lines.append(String(format: "Rebuffering: %d times · %.2f s", rebufferCount, rebufferSeconds))
        if isSeeking {
            lines.append(String(format: "Preparing seek: %.0f%%", seekBufferProgress * 100))
        }
        if let seekError { lines.append(seekError) }
        lines.append("Playback timing uses the first advancing player clock. Seek buffering estimates the byte position for variable bitrate files.")
        lines.append(diagnosticText)
        return lines.joined(separator: "\n")
    }

    private func finishStall() {
        if let started = stallStartedAt {
            rebufferSeconds += Date().timeIntervalSince(started)
            stallStartedAt = nil
        }
    }

    private func resetPlaybackMeasurements() {
        operationStartedAt = Date()
        downloadedBytes = 0
        streamingURL = nil
        completedFile = false
        selectedFileSize = 0
        nativePlaybackPosition = nil
        nativePlaybackBufferedBytes = 0
        nativePlaybackBufferTargetBytes = 0
        bufferedProgress = nil
        isSeeking = false
        seekBufferProgress = 0
        seekError = nil
        metadataSeconds = nil
        bufferReadySeconds = nil
        playbackBeganSeconds = nil
        rebufferCount = 0
        rebufferSeconds = 0
        stallStartedAt = nil
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
        onUpdate: ((EngineState, Double, Int, Double, Double, String) -> Void)?
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

        if let file = selectedVideoFile(in: snapshot.files) {
            selectedFileSize = max(0, file.sizeBytes ?? 0)
            downloadedBytes = max(0, file.bytesCompleted)
        } else {
            downloadedBytes = max(0, snapshot.bytesCompleted)
        }
        nativePlaybackPosition = snapshot.playbackPosition
        nativePlaybackBufferedBytes = max(0, snapshot.playbackBufferedBytes ?? 0)
        nativePlaybackBufferTargetBytes = max(0, snapshot.playbackBufferTargetBytes ?? 0)
        let contiguous = nativePlaybackPosition == nil
            ? max(0, snapshot.streamingBufferedBytes ?? 0)
            : nativePlaybackBufferedBytes
        if selectedFileSize > 0 {
            bufferedProgress = min(
                max(0, nativePlaybackPosition ?? 0) + Double(contiguous) / Double(selectedFileSize),
                1
            )
        }

        let normalizedProgress = max(0, min(fileProgress ?? 0, 1))
        let peers = snapshot.peerCount
            ?? snapshot.swarmDiagnostics?.connectedPeers
            ?? 0
        let speed = max(0, snapshot.liveBytesPerSecond ?? snapshot.bytesPerSecond ?? 0)
        let buffered = max(0, snapshot.streamingBufferedBytes ?? 0)
        let target = max(0, snapshot.streamingBufferTargetBytes ?? 0)
        let headProgress = target > 0
            ? min(max(Double(buffered) / Double(target), 0), 1)
            : 0
        let startupProgress = snapshot.streamingReadyPercent.map {
            min(max($0 / 100.0, 0), 1)
        } ?? headProgress

        downloadSpeed = speed
        bufferedBytes = buffered
        bufferTargetBytes = target
        cacheProgress = startupProgress

        update(
            streamingURL.map(EngineState.ready) ?? (resolving ? .resolving : .downloading),
            progress: normalizedProgress,
            peers: peers,
            speed: speed,
            cacheProgress: startupProgress,
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
        let previousPositionUpdate = positionUpdateTask
        previousPositionUpdate?.cancel()
        positionUpdateTask = nil
        seekRequestID = nil
        isSeeking = false
        finishStall()
        await previousPositionUpdate?.value
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
        speed: Double = 0,
        cacheProgress nextCacheProgress: Double = 0,
        diagnostics: String,
        onUpdate: ((EngineState, Double, Int, Double, Double, String) -> Void)?
    ) {
        state = nextState
        progress = nextProgress
        peerCount = peers
        downloadSpeed = speed
        cacheProgress = nextCacheProgress
        diagnosticText = diagnostics
        onUpdate?(nextState, nextProgress, peers, speed, nextCacheProgress, diagnostics)
    }

    private static func isSupportedVideo(_ path: String) -> Bool {
        switch URL(fileURLWithPath: path).pathExtension.lowercased() {
        case "mp4", "m4v", "mov", "mkv":
            true
        default:
            false
        }
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
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
