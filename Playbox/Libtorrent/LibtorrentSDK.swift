import Foundation

public enum LibtorrentRuntimeError: Error, LocalizedError, Sendable {
    case frameworkUnavailable
    case missingNativeSymbol(String)
    case nativeCallFailed(operation: String, code: Int32, message: String?)
    case invalidNativeEvent(String)

    public var errorDescription: String? {
        switch self {
        case .frameworkUnavailable:
            "The libtorrent XCFramework is not linked into this iOS build."
        case let .missingNativeSymbol(symbol):
            "The libtorrent native framework is missing required symbol '\(symbol)'."
        case let .nativeCallFailed(operation, code, message):
            if let message, !message.isEmpty {
                "The libtorrent native call '\(operation)' failed with code \(code): \(message)"
            } else {
                "The libtorrent native call '\(operation)' failed with code \(code)."
            }
        case let .invalidNativeEvent(reason):
            "The libtorrent native framework emitted an invalid event: \(reason)"
        }
    }
}

public struct LibtorrentJobInput: Sendable, Equatable, Codable {
    public let jobId: UUID
    public let magnetUri: String?
    public let torrentData: Data?
    public let torrentFileName: String?
    public let downloadDirectory: URL
    public let rateLimits: LibtorrentRateLimits?

    public init(
        jobId: UUID,
        magnetUri: String? = nil,
        torrentData: Data? = nil,
        torrentFileName: String? = nil,
        downloadDirectory: URL,
        rateLimits: LibtorrentRateLimits? = nil
    ) {
        self.jobId = jobId
        self.magnetUri = magnetUri
        self.torrentData = torrentData
        self.torrentFileName = torrentFileName
        self.downloadDirectory = downloadDirectory
        self.rateLimits = rateLimits
    }
}

public struct LibtorrentRateLimits: Sendable, Equatable, Codable {
    public let downloadBytesPerSecond: Int?
    public let uploadBytesPerSecond: Int?

    public init(
        downloadBytesPerSecond: Int? = nil,
        uploadBytesPerSecond: Int? = nil
    ) {
        self.downloadBytesPerSecond = downloadBytesPerSecond
        self.uploadBytesPerSecond = uploadBytesPerSecond
    }

    /// Libtorrent treats zero as unlimited, so use a one-byte cap for
    /// mobile sessions that should not participate in meaningful uploading.
    public static let mobileDownloadOnly = LibtorrentRateLimits(uploadBytesPerSecond: 1)
}

public struct LibtorrentFileSelection: Sendable, Equatable, Codable {
    public let all: Bool
    public let fileIndexes: [Int]
    public let globs: [String]
    public let primaryFileIndex: Int?
    public let priorityFileIndexes: [Int]

    public init(
        all: Bool = false,
        fileIndexes: [Int] = [],
        globs: [String] = [],
        primaryFileIndex: Int? = nil,
        priorityFileIndexes: [Int] = []
    ) {
        self.all = all
        self.fileIndexes = fileIndexes
        self.globs = globs
        self.primaryFileIndex = primaryFileIndex
        self.priorityFileIndexes = priorityFileIndexes
    }
}

public struct LibtorrentFileInfo: Sendable, Equatable, Identifiable, Codable {
    public let id: Int
    public let path: String
    public let sizeBytes: Int64?
    public let isSelected: Bool?
    public let bytesCompleted: Int64
    public let percentComplete: Double?
    public let localFileURL: URL?

    public init(
        id: Int,
        path: String,
        sizeBytes: Int64? = nil,
        isSelected: Bool? = nil,
        bytesCompleted: Int64 = 0,
        percentComplete: Double? = nil,
        localFileURL: URL? = nil
    ) {
        self.id = id
        self.path = path
        self.sizeBytes = sizeBytes
        self.isSelected = isSelected
        self.bytesCompleted = bytesCompleted
        self.percentComplete = percentComplete
        self.localFileURL = localFileURL
    }
}

/// Sanitized, live swarm information emitted by the native libtorrent bridge.
///
/// The bridge deliberately exposes tracker origins only. It never sends full
/// tracker URLs, tracker response text, peer addresses, or the device's
/// external address across the C ABI.
public struct LibtorrentSwarmDiagnostics: Sendable, Equatable, Codable {
    public let connectedPeers: Int?
    public let connectedSeeds: Int?
    /// Connected and half-open peer connections, as reported by libtorrent.
    public let connectionCount: Int?
    public let knownPeers: Int?
    public let knownSeeds: Int?
    public let connectCandidates: Int?
    public let trackerReportedSeeds: Int?
    public let trackerReportedLeechers: Int?
    public let nextAnnounceInSeconds: Int?
    public let hasIncomingConnections: Bool?
    public let trackers: [LibtorrentTrackerDiagnostics]
    public let dht: LibtorrentDHTDiagnostics?
    public let portMappings: [LibtorrentPortMappingDiagnostics]

    public init(
        connectedPeers: Int? = nil,
        connectedSeeds: Int? = nil,
        connectionCount: Int? = nil,
        knownPeers: Int? = nil,
        knownSeeds: Int? = nil,
        connectCandidates: Int? = nil,
        trackerReportedSeeds: Int? = nil,
        trackerReportedLeechers: Int? = nil,
        nextAnnounceInSeconds: Int? = nil,
        hasIncomingConnections: Bool? = nil,
        trackers: [LibtorrentTrackerDiagnostics] = [],
        dht: LibtorrentDHTDiagnostics? = nil,
        portMappings: [LibtorrentPortMappingDiagnostics] = []
    ) {
        self.connectedPeers = connectedPeers
        self.connectedSeeds = connectedSeeds
        self.connectionCount = connectionCount
        self.knownPeers = knownPeers
        self.knownSeeds = knownSeeds
        self.connectCandidates = connectCandidates
        self.trackerReportedSeeds = trackerReportedSeeds
        self.trackerReportedLeechers = trackerReportedLeechers
        self.nextAnnounceInSeconds = nextAnnounceInSeconds
        self.hasIncomingConnections = hasIncomingConnections
        self.trackers = trackers
        self.dht = dht
        self.portMappings = portMappings
    }
}

public struct LibtorrentTrackerDiagnostics: Sendable, Equatable, Codable, Identifiable {
    /// A scheme/host/port origin with all paths, query parameters, credentials,
    /// and passkeys removed by the native bridge.
    public let endpoint: String
    public let tier: Int?
    public let isVerified: Bool?
    public let consecutiveFailures: Int?
    public let isUpdating: Bool?
    public let lastEvent: String?
    public let lastEventAgeSeconds: Int?
    public let lastResponsePeerCount: Int?
    public let lastErrorCode: Int?
    public let lastHttpStatusCode: Int?

    public var id: String { endpoint }

    public init(
        endpoint: String,
        tier: Int? = nil,
        isVerified: Bool? = nil,
        consecutiveFailures: Int? = nil,
        isUpdating: Bool? = nil,
        lastEvent: String? = nil,
        lastEventAgeSeconds: Int? = nil,
        lastResponsePeerCount: Int? = nil,
        lastErrorCode: Int? = nil,
        lastHttpStatusCode: Int? = nil
    ) {
        self.endpoint = endpoint
        self.tier = tier
        self.isVerified = isVerified
        self.consecutiveFailures = consecutiveFailures
        self.isUpdating = isUpdating
        self.lastEvent = lastEvent
        self.lastEventAgeSeconds = lastEventAgeSeconds
        self.lastResponsePeerCount = lastResponsePeerCount
        self.lastErrorCode = lastErrorCode
        self.lastHttpStatusCode = lastHttpStatusCode
    }
}

public struct LibtorrentDHTDiagnostics: Sendable, Equatable, Codable {
    public let isRunning: Bool?
    public let nodeCount: Int?
    public let lastBootstrapAgeSeconds: Int?
    public let lastReplyPeerCount: Int?
    public let lastReplyAgeSeconds: Int?
    public let lastErrorCode: Int?

    public init(
        isRunning: Bool? = nil,
        nodeCount: Int? = nil,
        lastBootstrapAgeSeconds: Int? = nil,
        lastReplyPeerCount: Int? = nil,
        lastReplyAgeSeconds: Int? = nil,
        lastErrorCode: Int? = nil
    ) {
        self.isRunning = isRunning
        self.nodeCount = nodeCount
        self.lastBootstrapAgeSeconds = lastBootstrapAgeSeconds
        self.lastReplyPeerCount = lastReplyPeerCount
        self.lastReplyAgeSeconds = lastReplyAgeSeconds
        self.lastErrorCode = lastErrorCode
    }
}

public struct LibtorrentPortMappingDiagnostics: Sendable, Equatable, Codable, Identifiable {
    public let mappingIndex: Int
    public let transport: String?
    public let protocolName: String?
    public let status: String
    public let lastEventAgeSeconds: Int?
    public let lastErrorCode: Int?

    public var id: Int { mappingIndex }

    public init(
        mappingIndex: Int,
        transport: String? = nil,
        protocolName: String? = nil,
        status: String,
        lastEventAgeSeconds: Int? = nil,
        lastErrorCode: Int? = nil
    ) {
        self.mappingIndex = mappingIndex
        self.transport = transport
        self.protocolName = protocolName
        self.status = status
        self.lastEventAgeSeconds = lastEventAgeSeconds
        self.lastErrorCode = lastErrorCode
    }
}

public struct LibtorrentProgress: Sendable, Equatable, Codable {
    public let jobId: UUID
    public let status: String
    public let name: String?
    public let infoHash: String?
    public let bytesCompleted: Int64
    public let totalBytes: Int64?
    public let percentComplete: Double?
    public let bytesPerSecond: Double?
    public let totalBytesPerSecond: Double?
    public let protocolBytesPerSecond: Double?
    public let peerCount: Int?
    public let swarmDiagnostics: LibtorrentSwarmDiagnostics?
    public let files: [LibtorrentFileInfo]

    public init(
        jobId: UUID,
        status: String,
        name: String? = nil,
        infoHash: String? = nil,
        bytesCompleted: Int64 = 0,
        totalBytes: Int64? = nil,
        percentComplete: Double? = nil,
        bytesPerSecond: Double? = nil,
        totalBytesPerSecond: Double? = nil,
        protocolBytesPerSecond: Double? = nil,
        peerCount: Int? = nil,
        swarmDiagnostics: LibtorrentSwarmDiagnostics? = nil,
        files: [LibtorrentFileInfo] = []
    ) {
        self.jobId = jobId
        self.status = status
        self.name = name
        self.infoHash = infoHash
        self.bytesCompleted = bytesCompleted
        self.totalBytes = totalBytes
        self.percentComplete = percentComplete
        self.bytesPerSecond = bytesPerSecond
        self.totalBytesPerSecond = totalBytesPerSecond
        self.protocolBytesPerSecond = protocolBytesPerSecond
        self.peerCount = peerCount
        self.swarmDiagnostics = swarmDiagnostics
        self.files = files
    }
}

public struct LibtorrentStreamReadiness: Sendable, Equatable, Codable {
    public let jobId: UUID
    public let primaryFileIndex: Int
    public let fileURL: URL
    public let bytesAvailable: Int64
    public let totalBytes: Int64?

    public init(
        jobId: UUID,
        primaryFileIndex: Int,
        fileURL: URL,
        bytesAvailable: Int64,
        totalBytes: Int64? = nil
    ) {
        self.jobId = jobId
        self.primaryFileIndex = primaryFileIndex
        self.fileURL = fileURL
        self.bytesAvailable = bytesAvailable
        self.totalBytes = totalBytes
    }
}

public enum LibtorrentEvent: Sendable, Equatable {
    case progress(LibtorrentProgress)
    case streamReady(LibtorrentStreamReadiness)
    case completed(LibtorrentProgress)
}

public protocol LibtorrentSession: Sendable {
    func start(
        input: LibtorrentJobInput,
        selection: LibtorrentFileSelection?,
        eventHandler: @escaping @Sendable (LibtorrentEvent) async -> Void
    ) async throws

    func applySelection(jobId: UUID, selection: LibtorrentFileSelection) async throws
    func updateRateLimits(jobId: UUID, rateLimits: LibtorrentRateLimits) async throws
    func reannounce(jobId: UUID) async throws
    func refreshPeers(jobId: UUID) async throws
    func pause(jobId: UUID) async throws
    func resume(jobId: UUID) async throws
    func cancel(jobId: UUID) async throws
}

public enum LibtorrentSessionFactory {
    public static func makeDefault() -> any LibtorrentSession {
        #if canImport(Darwin)
            if let nativeSession = try? NativeLibtorrentSession() {
                return nativeSession
            }
        #endif
        return UnavailableLibtorrentSession()
    }
}

public struct UnavailableLibtorrentSession: LibtorrentSession {
    public init() {}

    public func start(
        input _: LibtorrentJobInput,
        selection _: LibtorrentFileSelection?,
        eventHandler _: @escaping @Sendable (LibtorrentEvent) async -> Void
    ) async throws {
        throw LibtorrentRuntimeError.frameworkUnavailable
    }

    public func applySelection(jobId _: UUID, selection _: LibtorrentFileSelection) async throws {
        throw LibtorrentRuntimeError.frameworkUnavailable
    }

    public func updateRateLimits(jobId _: UUID, rateLimits _: LibtorrentRateLimits) async throws {
        throw LibtorrentRuntimeError.frameworkUnavailable
    }

    public func reannounce(jobId _: UUID) async throws {
        throw LibtorrentRuntimeError.frameworkUnavailable
    }

    public func refreshPeers(jobId _: UUID) async throws {
        throw LibtorrentRuntimeError.frameworkUnavailable
    }

    public func pause(jobId _: UUID) async throws {
        throw LibtorrentRuntimeError.frameworkUnavailable
    }

    public func resume(jobId _: UUID) async throws {
        throw LibtorrentRuntimeError.frameworkUnavailable
    }

    public func cancel(jobId _: UUID) async throws {
        throw LibtorrentRuntimeError.frameworkUnavailable
    }
}
