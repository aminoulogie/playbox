#!/usr/bin/env python3
from pathlib import Path
import sys


def replace_exact(path: Path, old: str, new: str, label: str) -> None:
    text = path.read_text()
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label}: expected exactly one match in {path}, found {count}")
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

    print("SwiftTorrent peer-discovery patches applied successfully")


if __name__ == "__main__":
    main()
