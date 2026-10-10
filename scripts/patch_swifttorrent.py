#!/usr/bin/env python3
from pathlib import Path
import stat
import sys


def replace_exact(path: Path, old: str, new: str, label: str) -> None:
    text = path.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one match in {path}, found {count}")
    path.chmod(path.stat().st_mode | stat.S_IWUSR)
    path.write_text(text.replace(old, new, 1))
    print(f"patched {label}: {path}")


def main() -> None:
    if len(sys.argv) != 2:
        raise SystemExit("usage: patch_swifttorrent.py <swift-torrent checkout>")

    root = Path(sys.argv[1])
    if not root.is_dir():
        raise SystemExit(f"SwiftTorrent checkout not found: {root}")

    http_tracker = root / "Sources/SwiftTorrent/Tracker/HTTPTracker.swift"
    tracker_manager = root / "Sources/SwiftTorrent/Tracker/TrackerManager.swift"
    peer_connection = root / "Sources/SwiftTorrent/Peer/PeerConnection.swift"
    peer_manager = root / "Sources/SwiftTorrent/Peer/PeerManager.swift"
    torrent_handle = root / "Sources/SwiftTorrent/Session/TorrentHandle.swift"
    session = root / "Sources/SwiftTorrent/Session/Session.swift"
    dht_node = root / "Sources/SwiftTorrent/DHT/DHTNode.swift"

    replace_exact(
        http_tracker,
        '''    public func announce(params: AnnounceParams) async throws -> AnnounceResponse {
        var components = URLComponents(string: announceURL)
        components?.queryItems = [
            URLQueryItem(name: "info_hash", value: params.infoHash.urlEncoded),
            URLQueryItem(name: "peer_id", value: String(data: params.peerID, encoding: .ascii) ?? ""),
            URLQueryItem(name: "port", value: String(params.port)),
            URLQueryItem(name: "uploaded", value: String(params.uploaded)),
            URLQueryItem(name: "downloaded", value: String(params.downloaded)),
            URLQueryItem(name: "left", value: String(params.left)),
            URLQueryItem(name: "compact", value: "1"),
            URLQueryItem(name: "numwant", value: String(params.numWant)),
        ]
        if let event = params.event {
            components?.queryItems?.append(URLQueryItem(name: "event", value: event))
        }

        guard let url = components?.url else {
            throw TrackerError.invalidURL
        }

        let (data, _) = try await URLSession.shared.data(from: url)
        return try parseAnnounceResponse(data)
    }
''',
        '''    public func announce(params: AnnounceParams) async throws -> AnnounceResponse {
        // BitTorrent tracker fields are raw bytes. Build this query manually so
        // Foundation cannot double-escape an already percent-encoded info_hash.
        let encodedInfoHash = params.infoHash.bytes
            .map { String(format: "%%%02X", $0) }
            .joined()
        let encodedPeerID = params.peerID
            .map { String(format: "%%%02X", $0) }
            .joined()

        var query = [
            "info_hash=\\(encodedInfoHash)",
            "peer_id=\\(encodedPeerID)",
            "port=\\(params.port)",
            "uploaded=\\(params.uploaded)",
            "downloaded=\\(params.downloaded)",
            "left=\\(params.left)",
            "compact=1",
            "numwant=\\(params.numWant)",
        ]
        if let event = params.event {
            query.append("event=\\(event)")
        }

        let separator: String
        if announceURL.contains("?") {
            separator = announceURL.hasSuffix("?") || announceURL.hasSuffix("&") ? "" : "&"
        } else {
            separator = "?"
        }

        guard let url = URL(string: announceURL + separator + query.joined(separator: "&")) else {
            throw TrackerError.invalidURL
        }

        let (data, _) = try await URLSession.shared.data(from: url)
        return try parseAnnounceResponse(data)
    }
''',
        "HTTP tracker binary query encoding",
    )

    replace_exact(
        tracker_manager,
        '''    public func announce(params: AnnounceParams) async throws -> AnnounceResponse {
        for tier in tiers {
            for urlString in tier {
                do {
                    let response: AnnounceResponse
                    if urlString.hasPrefix("http://") || urlString.hasPrefix("https://") {
                        let tracker = HTTPTracker(announceURL: urlString)
                        response = try await tracker.announce(params: params)
                    } else if urlString.hasPrefix("udp://") {
                        guard let components = URLComponents(string: urlString),
                              let host = components.host,
                              let port = components.port else {
                            continue
                        }
                        let tracker = UDPTracker(host: host, port: port, group: group)
                        response = try await tracker.announce(params: params)
                    } else {
                        continue
                    }
                    lastResponse = response
                    announceInterval = response.interval
                    return response
                } catch {
                    continue // Try next tracker in tier
                }
            }
        }
        throw TrackerError.connectionFailed
    }
''',
        '''    public func announce(params: AnnounceParams) async throws -> AnnounceResponse {
        var firstSuccessfulResponse: AnnounceResponse?

        for tier in tiers {
            for urlString in tier {
                do {
                    let response: AnnounceResponse
                    if urlString.hasPrefix("http://") || urlString.hasPrefix("https://") {
                        let tracker = HTTPTracker(announceURL: urlString)
                        response = try await tracker.announce(params: params)
                    } else if urlString.hasPrefix("udp://") {
                        guard let components = URLComponents(string: urlString),
                              let host = components.host,
                              let port = components.port else {
                            continue
                        }
                        let tracker = UDPTracker(host: host, port: port, group: group)
                        response = try await tracker.announce(params: params)
                    } else {
                        continue
                    }

                    lastResponse = response
                    announceInterval = response.interval
                    if firstSuccessfulResponse == nil {
                        firstSuccessfulResponse = response
                    }

                    // A tracker can successfully announce while returning no peers.
                    // Keep trying the remaining trackers until one returns candidates.
                    if !response.peers.isEmpty {
                        return response
                    }
                } catch {
                    continue // Try next tracker in tier
                }
            }
        }

        if let response = firstSuccessfulResponse {
            return response
        }
        throw TrackerError.connectionFailed
    }
''',
        "tracker fallback when an announce returns zero peers",
    )

    replace_exact(
        peer_connection,
        '''        // Add the message encoder after handshake is sent
        try await ch.pipeline.addHandler(PeerMessageEncoder()).get()

        // Store remote handshake info
        self.remotePeerID = decoder.remotePeerID
        self.supportsExtensions = decoder.remoteSupportsExtensions

        return ch
''',
        '''        // Add the message encoder after handshake is sent
        try await ch.pipeline.addHandler(PeerMessageEncoder()).get()

        // The TCP connect completing does not mean the remote BitTorrent handshake
        // has arrived. Wait for the decoder to receive it before deciding whether
        // BEP-10 extensions (required for magnet metadata exchange) are supported.
        for _ in 0..<100 {
            if decoder.remotePeerID != nil {
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }

        guard let remotePeerID = decoder.remotePeerID else {
            try? await ch.close().get()
            throw PeerConnectionError.handshakeFailed
        }

        self.remotePeerID = remotePeerID
        self.supportsExtensions = decoder.remoteSupportsExtensions

        return ch
''',
        "wait for remote peer handshake",
    )

    replace_exact(
        torrent_handle,
        '''    /// Returns the file entries for this torrent, or nil if metadata is not yet available.
    public func getFiles() -> [TorrentInfo.FileEntry]? {
        info?.files
    }
''',
        '''    /// Feed a peer discovered outside the tracker path (for example DHT)
    /// into the same peer manager used by tracker announces.
    internal func addDiscoveredPeer(address: String, port: UInt16) async {
        await peerManager.addPeer(address: address, port: port)
    }

    /// Returns the file entries for this torrent, or nil if metadata is not yet available.
    public func getFiles() -> [TorrentInfo.FileEntry]? {
        info?.files
    }
''',
        "allow DHT peers to enter TorrentHandle",
    )

    replace_exact(
        session,
        '''    /// Start DHT if enabled.
    public func startDHT() async throws {
        guard settings.dhtEnabled else { return }
        let node = DHTNode(port: settings.dhtPort, group: group)
        try await node.start()
        self.dhtNode = node
    }
''',
        '''    /// Start DHT if enabled.
    public func startDHT() async throws {
        guard settings.dhtEnabled else { return }
        guard dhtNode == nil else { return }

        let node = DHTNode(port: settings.dhtPort, group: group)
        try await node.start()
        self.dhtNode = node
    }

    /// Discover peers for an active torrent through BEP-5 DHT and feed them
    /// into its TorrentHandle. Trackers continue running in parallel.
    @discardableResult
    public func discoverPeers(for infoHash: InfoHash) async -> Int {
        guard settings.dhtEnabled,
              let node = dhtNode,
              let handle = torrents[infoHash] else {
            return 0
        }

        // Bootstrap responses arrive asynchronously. Give the routing table a
        // short window to receive at least one node before starting traversal.
        for _ in 0..<10 {
            if Task.isCancelled { return 0 }
            if await node.nodeCount() > 0 { break }
            try? await Task.sleep(for: .milliseconds(300))
        }

        if Task.isCancelled { return 0 }

        let traversal = DHTTraversal(dhtNode: node)
        guard let peers = try? await traversal.getPeers(infoHash: infoHash) else {
            return 0
        }

        if Task.isCancelled { return 0 }

        var seen = Set<String>()
        var added = 0
        for (address, port) in peers {
            let key = "\\(address):\\(port)"
            guard seen.insert(key).inserted else { continue }
            await handle.addDiscoveredPeer(address: address, port: port)
            added += 1
        }
        return added
    }
''',
        "wire DHT traversal into active torrents",
    )

    replace_exact(
        dht_node,
        '''    /// Bootstrap by contacting well-known DHT nodes.
    private func bootstrap() async {
''',
        '''    /// Stop the DHT socket so sessions can be cancelled/restarted safely.
    public func stop() async throws {
        if let channel {
            try await channel.close().get()
            self.channel = nil
        }
        responseHandler = nil

        let pending = pendingQueries
        pendingQueries.removeAll()
        for (_, continuation) in pending {
            continuation.resume(throwing: CancellationError())
        }
    }

    /// Bootstrap by contacting well-known nodes
    private func bootstrap() async {
''',
        "add DHT socket shutdown",
    )

    replace_exact(
        session,
        '''    /// Shutdown the session.
    public func shutdown() async throws {
        await pauseAll()
        alertContinuation.finish()
        try await group.shutdownGracefully()
    }
''',
        '''    /// Shutdown the session.
    public func shutdown() async throws {
        await pauseAll()
        if let dhtNode {
            try? await dhtNode.stop()
            self.dhtNode = nil
        }
        alertContinuation.finish()
        try await group.shutdownGracefully()
    }
''',
        "stop DHT before session shutdown",
    )


    replace_exact(
        torrent_handle,
        '''            let left = info?.totalSize ?? 0
            let params = AnnounceParams(
                infoHash: infoHash, peerID: peerID, port: 6881,
                left: left - totalDownloaded, event: "started"
            )
''',
        '''            // Before magnet metadata arrives, total size is unknown. Do not
            // announce left=0 because trackers interpret that as "already seeding"
            // and may return only leechers instead of the seeders needed for metadata.
            let left = info?.totalSize ?? 1
            let params = AnnounceParams(
                infoHash: infoHash, peerID: peerID, port: 6881,
                left: max(left - totalDownloaded, 1), event: "started"
            )
''',
        "announce metadata-less magnets as incomplete",
    )

    replace_exact(
        dht_node,
        '''    public func sendAndWait(_ msg: DHTMessage, to address: String, port: UInt16, timeout: Duration = .seconds(5)) async throws -> DHTMessage {
        guard case .query(let txID, _, _) = msg else {
            throw DHTMessageError.invalidMessage
        }
        try await sendMessage(msg, to: address, port: port)

        return try await withCheckedThrowingContinuation { continuation in
            self.pendingQueries[txID] = continuation

            Task {
                try? await Task.sleep(for: timeout)
                if let cont = self.pendingQueries.removeValue(forKey: txID) {
                    cont.resume(throwing: DHTMessageError.invalidMessage)
                }
            }
        }
    }
''',
        '''    public func sendAndWait(_ msg: DHTMessage, to address: String, port: UInt16, timeout: Duration = .seconds(5)) async throws -> DHTMessage {
        guard case .query(let txID, _, _) = msg else {
            throw DHTMessageError.invalidMessage
        }

        // Register the waiter before writing the datagram. The old order sent the
        // query first, so a fast UDP reply could arrive before pendingQueries had
        // an entry and be silently discarded.
        return try await withCheckedThrowingContinuation { continuation in
            self.pendingQueries[txID] = continuation

            Task {
                do {
                    try await self.sendMessage(msg, to: address, port: port)
                } catch {
                    if let cont = await self.removePendingQuery(txID) {
                        cont.resume(throwing: error)
                    }
                    return
                }

                try? await Task.sleep(for: timeout)
                if let cont = await self.removePendingQuery(txID) {
                    cont.resume(throwing: DHTMessageError.invalidMessage)
                }
            }
        }
    }

    private func removePendingQuery(_ txID: Data) -> CheckedContinuation<DHTMessage, Error>? {
        pendingQueries.removeValue(forKey: txID)
    }
''',
        "register DHT response waiter before sending",
    )

    replace_exact(
        peer_manager,
        '''/// Manages the pool of peer connections for a torrent.
public actor PeerManager {
''',
        '''public struct PeerConnectionDiagnostics: Sendable {
    public let active: Int
    public let connected: Int
    public let attempts: Int
    public let failures: Int
}

/// Manages the pool of peer connections for a torrent.
public actor PeerManager {
''',
        "add peer connection diagnostics type",
    )

    replace_exact(
        peer_manager,
        '''    private let maxConnections: Int

    public var pieceManager: PieceManager?
''',
        '''    private let maxConnections: Int
    private var totalConnectionAttempts: Int = 0
    private var totalConnectionFailures: Int = 0

    public var pieceManager: PieceManager?
''',
        "track peer connection attempts",
    )

    replace_exact(
        peer_manager,
        '''        guard connections.count < maxConnections else { return }

        let conn = PeerConnection(address: address, port: port, infoHash: infoHash, peerID: peerID)
''',
        '''        guard connections.count < maxConnections else { return }

        totalConnectionAttempts += 1
        let conn = PeerConnection(address: address, port: port, infoHash: infoHash, peerID: peerID)
''',
        "count peer connection attempts",
    )

    replace_exact(
        peer_manager,
        '''            } catch {
                await self.removePeerByKey(key)
            }
''',
        '''            } catch {
                await self.recordConnectionFailure()
                await self.removePeerByKey(key)
            }
''',
        "count peer connection failures",
    )

    replace_exact(
        peer_manager,
        '''    private func removePeerByKey(_ key: String) {
        connections.removeValue(forKey: key)
''',
        '''    private func recordConnectionFailure() {
        totalConnectionFailures += 1
    }

    private func removePeerByKey(_ key: String) {
        connections.removeValue(forKey: key)
''',
        "record peer connection failures",
    )

    replace_exact(
        peer_manager,
        '''    /// Number of active connections.
    public var connectionCount: Int {
        connections.count
    }

    /// Number of peers that completed the TCP handshake.
''',
        '''    public func diagnostics() -> PeerConnectionDiagnostics {
        PeerConnectionDiagnostics(
            active: connections.count,
            connected: connectedPeers.count,
            attempts: totalConnectionAttempts,
            failures: totalConnectionFailures
        )
    }

    /// Number of active connections.
    public var connectionCount: Int {
        connections.count
    }

    /// Number of peers that completed the TCP handshake.
''',
        "expose peer connection diagnostics",
    )

    replace_exact(
        torrent_handle,
        '''/// Per-torrent controller tying peers, pieces, and disk together.
public actor TorrentHandle {
''',
        '''public struct TorrentDiscoveryDiagnostics: Sendable {
    public let trackerPeers: Int
    public let trackerSeeders: Int
    public let trackerLeechers: Int
    public let trackerFailures: Int
    public let dhtPeers: Int
    public let dhtNodes: Int
    public let activePeers: Int
    public let connectedPeers: Int
    public let connectionAttempts: Int
    public let connectionFailures: Int
}

/// Per-torrent controller tying peers, pieces, and disk together.
public actor TorrentHandle {
''',
        "add torrent discovery diagnostics type",
    )

    replace_exact(
        torrent_handle,
        '''    private var nextWaitID: UInt64 = 0

    public init(params: AddTorrentParams, settings: SessionSettings, group: EventLoopGroup) {
''',
        '''    private var nextWaitID: UInt64 = 0
    private var lastTrackerPeerCount: Int = 0
    private var lastTrackerSeederCount: Int = 0
    private var lastTrackerLeecherCount: Int = 0
    private var trackerFailureCount: Int = 0
    private var dhtPeerCount: Int = 0
    private var dhtNodeCount: Int = 0

    public init(params: AddTorrentParams, settings: SessionSettings, group: EventLoopGroup) {
''',
        "store torrent discovery diagnostics",
    )

    replace_exact(
        torrent_handle,
        '''    private func announceToAllTrackers(trackerMgr: TrackerManager, params: AnnounceParams) async {
        if let response = try? await trackerMgr.announce(params: params) {
            for (address, port) in response.peers {
                await peerManager.addPeer(address: address, port: port)
            }
        }
    }
''',
        '''    private func announceToAllTrackers(trackerMgr: TrackerManager, params: AnnounceParams) async {
        do {
            let response = try await trackerMgr.announce(params: params)
            lastTrackerPeerCount = response.peers.count
            lastTrackerSeederCount = response.seeders
            lastTrackerLeecherCount = response.leechers
            for (address, port) in response.peers {
                await peerManager.addPeer(address: address, port: port)
            }
        } catch {
            trackerFailureCount += 1
        }
    }
''',
        "record tracker announce diagnostics",
    )

    replace_exact(
        torrent_handle,
        '''    /// Returns the file entries for this torrent, or nil if metadata is not yet available.
    public func getFiles() -> [TorrentInfo.FileEntry]? {
        info?.files
    }
''',
        '''    internal func recordDHTDiscovery(peers: Int, nodes: Int) {
        dhtPeerCount = max(dhtPeerCount, peers)
        dhtNodeCount = max(dhtNodeCount, nodes)
    }

    public func discoveryDiagnostics() async -> TorrentDiscoveryDiagnostics {
        let peer = await peerManager.diagnostics()
        return TorrentDiscoveryDiagnostics(
            trackerPeers: lastTrackerPeerCount,
            trackerSeeders: lastTrackerSeederCount,
            trackerLeechers: lastTrackerLeecherCount,
            trackerFailures: trackerFailureCount,
            dhtPeers: dhtPeerCount,
            dhtNodes: dhtNodeCount,
            activePeers: peer.active,
            connectedPeers: peer.connected,
            connectionAttempts: peer.attempts,
            connectionFailures: peer.failures
        )
    }

    /// Returns the file entries for this torrent, or nil if metadata is not yet available.
    public func getFiles() -> [TorrentInfo.FileEntry]? {
        info?.files
    }
''',
        "expose torrent discovery diagnostics",
    )

    replace_exact(
        session,
        '''        let traversal = DHTTraversal(dhtNode: node)
        guard let peers = try? await traversal.getPeers(infoHash: infoHash) else {
            return 0
        }

        if Task.isCancelled { return 0 }

        var seen = Set<String>()
''',
        '''        let nodes = await node.nodeCount()
        let traversal = DHTTraversal(dhtNode: node)
        guard let peers = try? await traversal.getPeers(infoHash: infoHash) else {
            await handle.recordDHTDiscovery(peers: 0, nodes: nodes)
            return 0
        }

        if Task.isCancelled { return 0 }

        var seen = Set<String>()
''',
        "record DHT node diagnostics",
    )

    replace_exact(
        session,
        '''            await handle.addDiscoveredPeer(address: address, port: port)
            added += 1
        }
        return added
''',
        '''            await handle.addDiscoveredPeer(address: address, port: port)
            added += 1
        }
        await handle.recordDHTDiscovery(peers: added, nodes: await node.nodeCount())
        return added
''',
        "record DHT peer diagnostics",
    )

    print("SwiftTorrent peer-discovery and DHT patches applied successfully")


if __name__ == "__main__":
    main()
