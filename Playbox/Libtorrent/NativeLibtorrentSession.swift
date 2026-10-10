import Foundation

#if canImport(Darwin)
    import Darwin

    // The native function table is immutable after initialization. Mutable Swift
    // state is limited to event handlers and is protected by stateLock.
    public final class NativeLibtorrentSession: @unchecked Sendable, LibtorrentSession {
        private let library: NativeLibtorrentLibrary
        private let handle: OpaquePointer
        private let eventBridge: NativeLibtorrentEventBridge
        private let stateLock = NSLock()
        private var eventHandlersByJobId: [UUID: @Sendable (LibtorrentEvent) async -> Void] = [:]

        public convenience init() throws {
            try self.init(library: try NativeLibtorrentLibrary.load())
        }

        public init(library: NativeLibtorrentLibrary) throws {
            self.library = library
            self.eventBridge = NativeLibtorrentEventBridge()

            var nativeHandle: OpaquePointer?
            let context = Unmanaged.passUnretained(eventBridge).toOpaque()
            let code = library.create(nativeEventCallback, context, &nativeHandle)
            guard code == 0, let nativeHandle else {
                throw LibtorrentRuntimeError.nativeCallFailed(
                    operation: "create",
                    code: code,
                    message: nil
                )
            }

            self.handle = nativeHandle
            eventBridge.install { [weak self] event in
                guard let self else { return }
                Task {
                    await self.dispatch(event)
                }
            }
        }

        deinit {
            library.destroy(handle)
        }

        public func start(
            input: LibtorrentJobInput,
            selection: LibtorrentFileSelection?,
            eventHandler: @escaping @Sendable (LibtorrentEvent) async -> Void
        ) async throws {
            let payload = NativeLibtorrentStartRequest(input: input, selection: selection)
            let json = try Self.encode(payload)
            setEventHandler(eventHandler, for: input.jobId)

            let code = json.withCString { pointer in
                library.start(handle, pointer)
            }
            guard code == 0 else {
                removeEventHandler(for: input.jobId)
                throw nativeError(operation: "start", code: code)
            }
        }

        public func applySelection(jobId: UUID, selection: LibtorrentFileSelection) async throws {
            try perform(
                operation: "apply_selection",
                request: NativeLibtorrentSelectionRequest(jobId: jobId, selection: selection),
                command: library.applySelection
            )
        }

        public func updateRateLimits(jobId: UUID, rateLimits: LibtorrentRateLimits) async throws {
            guard let command = library.updateRateLimits else {
                throw LibtorrentRuntimeError.missingNativeSymbol("tryagi_libtorrent_job_update_rate_limits")
            }

            try perform(
                operation: "update_rate_limits",
                request: NativeLibtorrentRateLimitsRequest(jobId: jobId, rateLimits: rateLimits),
                command: command
            )
        }

        public func reannounce(jobId: UUID) async throws {
            guard let command = library.reannounce else {
                throw LibtorrentRuntimeError.missingNativeSymbol("tryagi_libtorrent_job_reannounce")
            }

            try perform(
                operation: "reannounce",
                request: NativeLibtorrentJobControlRequest(jobId: jobId),
                command: command
            )
        }

        public func refreshPeers(jobId: UUID) async throws {
            guard let command = library.refreshPeers else {
                throw LibtorrentRuntimeError.missingNativeSymbol("tryagi_libtorrent_job_refresh_peers")
            }

            try perform(
                operation: "refresh_peers",
                request: NativeLibtorrentJobControlRequest(jobId: jobId),
                command: command
            )
        }

        public func pause(jobId: UUID) async throws {
            try perform(
                operation: "pause",
                request: NativeLibtorrentJobControlRequest(jobId: jobId),
                command: library.pause
            )
        }

        public func resume(jobId: UUID) async throws {
            try perform(
                operation: "resume",
                request: NativeLibtorrentJobControlRequest(jobId: jobId),
                command: library.resume
            )
        }

        public func cancel(jobId: UUID) async throws {
            defer { removeEventHandler(for: jobId) }
            try perform(
                operation: "cancel",
                request: NativeLibtorrentJobControlRequest(jobId: jobId),
                command: library.cancel
            )
        }

        private func dispatch(_ event: LibtorrentEvent) async {
            let jobId = event.jobId
            let shouldRemoveHandler: Bool
            if case .completed = event {
                shouldRemoveHandler = true
            } else {
                shouldRemoveHandler = false
            }

            let handler = eventHandler(for: jobId, removing: shouldRemoveHandler)

            await handler?(event)
        }

        private func perform<T: Encodable>(
            operation: String,
            request: T,
            command: NativeLibtorrentLibrary.NativeJSONCommand
        ) throws {
            let json = try Self.encode(request)
            let code = json.withCString { pointer in
                command(handle, pointer)
            }
            guard code == 0 else {
                throw nativeError(operation: operation, code: code)
            }
        }

        private func removeEventHandler(for jobId: UUID) {
            stateLock.lock()
            eventHandlersByJobId[jobId] = nil
            stateLock.unlock()
        }

        private func setEventHandler(
            _ eventHandler: @escaping @Sendable (LibtorrentEvent) async -> Void,
            for jobId: UUID
        ) {
            stateLock.lock()
            eventHandlersByJobId[jobId] = eventHandler
            stateLock.unlock()
        }

        private func eventHandler(
            for jobId: UUID,
            removing shouldRemoveHandler: Bool
        ) -> (@Sendable (LibtorrentEvent) async -> Void)? {
            stateLock.lock()
            let handler = eventHandlersByJobId[jobId]
            if shouldRemoveHandler {
                eventHandlersByJobId[jobId] = nil
            }
            stateLock.unlock()
            return handler
        }

        private func nativeError(operation: String, code: Int32) -> LibtorrentRuntimeError {
            let message = library.lastError(handle).map(String.init(cString:))
            return .nativeCallFailed(operation: operation, code: code, message: message)
        }

        private static func encode(_ value: some Encodable) throws -> String {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(value)
            guard let json = String(data: data, encoding: .utf8) else {
                throw LibtorrentRuntimeError.invalidNativeEvent("Failed to UTF-8 encode native request JSON.")
            }
            return json
        }
    }

    public final class NativeLibtorrentLibrary: @unchecked Sendable {
        public typealias NativeEventCallback = @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void
        public typealias NativeCreate = @convention(c) (
            NativeEventCallback?,
            UnsafeMutableRawPointer?,
            UnsafeMutablePointer<OpaquePointer?>?
        ) -> Int32
        public typealias NativeDestroy = @convention(c) (OpaquePointer?) -> Void
        public typealias NativeJSONCommand = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?) -> Int32
        public typealias NativeLastError = @convention(c) (OpaquePointer?) -> UnsafePointer<CChar>?

        let create: NativeCreate
        let destroy: NativeDestroy
        let start: NativeJSONCommand
        let applySelection: NativeJSONCommand
        let updateRateLimits: NativeJSONCommand?
        let reannounce: NativeJSONCommand?
        let refreshPeers: NativeJSONCommand?
        let pause: NativeJSONCommand
        let resume: NativeJSONCommand
        let cancel: NativeJSONCommand
        let lastError: NativeLastError

        private let dynamicLibraryHandle: UnsafeMutableRawPointer?
        private let shouldCloseDynamicLibrary: Bool

        @_spi(Testing) public init(
            create: @escaping NativeCreate,
            destroy: @escaping NativeDestroy,
            start: @escaping NativeJSONCommand,
            applySelection: @escaping NativeJSONCommand,
            updateRateLimits: NativeJSONCommand? = nil,
            reannounce: NativeJSONCommand? = nil,
            refreshPeers: NativeJSONCommand? = nil,
            pause: @escaping NativeJSONCommand,
            resume: @escaping NativeJSONCommand,
            cancel: @escaping NativeJSONCommand,
            lastError: @escaping NativeLastError
        ) {
            self.dynamicLibraryHandle = nil
            self.shouldCloseDynamicLibrary = false
            self.create = create
            self.destroy = destroy
            self.start = start
            self.applySelection = applySelection
            self.updateRateLimits = updateRateLimits
            self.reannounce = reannounce
            self.refreshPeers = refreshPeers
            self.pause = pause
            self.resume = resume
            self.cancel = cancel
            self.lastError = lastError
        }

        deinit {
            if shouldCloseDynamicLibrary, let dynamicLibraryHandle {
                dlclose(dynamicLibraryHandle)
            }
        }

        public static func load() throws -> NativeLibtorrentLibrary {
            var missingSymbols: [String] = []
            for candidate in dynamicLibraryCandidates() {
                guard let handle = candidate.open() else {
                    continue
                }

                do {
                    return try NativeLibtorrentLibrary(
                        dynamicLibraryHandle: handle,
                        shouldCloseDynamicLibrary: candidate.shouldClose,
                        missingSymbols: &missingSymbols
                    )
                } catch {
                    if candidate.shouldClose {
                        dlclose(handle)
                    }
                    continue
                }
            }

            if let missingSymbol = missingSymbols.first {
                throw LibtorrentRuntimeError.missingNativeSymbol(missingSymbol)
            }
            throw LibtorrentRuntimeError.frameworkUnavailable
        }

        private init(
            dynamicLibraryHandle: UnsafeMutableRawPointer,
            shouldCloseDynamicLibrary: Bool,
            missingSymbols: inout [String]
        ) throws {
            self.dynamicLibraryHandle = dynamicLibraryHandle
            self.shouldCloseDynamicLibrary = shouldCloseDynamicLibrary
            self.create = try Self.loadSymbol(
                "tryagi_libtorrent_session_create",
                from: dynamicLibraryHandle,
                missingSymbols: &missingSymbols,
                as: NativeCreate.self
            )
            self.destroy = try Self.loadSymbol(
                "tryagi_libtorrent_session_destroy",
                from: dynamicLibraryHandle,
                missingSymbols: &missingSymbols,
                as: NativeDestroy.self
            )
            self.start = try Self.loadSymbol(
                "tryagi_libtorrent_job_start",
                from: dynamicLibraryHandle,
                missingSymbols: &missingSymbols,
                as: NativeJSONCommand.self
            )
            self.applySelection = try Self.loadSymbol(
                "tryagi_libtorrent_job_apply_selection",
                from: dynamicLibraryHandle,
                missingSymbols: &missingSymbols,
                as: NativeJSONCommand.self
            )
            self.updateRateLimits = Self.loadOptionalSymbol(
                "tryagi_libtorrent_job_update_rate_limits",
                from: dynamicLibraryHandle,
                as: NativeJSONCommand.self
            )
            self.reannounce = Self.loadOptionalSymbol(
                "tryagi_libtorrent_job_reannounce",
                from: dynamicLibraryHandle,
                as: NativeJSONCommand.self
            )
            self.refreshPeers = Self.loadOptionalSymbol(
                "tryagi_libtorrent_job_refresh_peers",
                from: dynamicLibraryHandle,
                as: NativeJSONCommand.self
            )
            self.pause = try Self.loadSymbol(
                "tryagi_libtorrent_job_pause",
                from: dynamicLibraryHandle,
                missingSymbols: &missingSymbols,
                as: NativeJSONCommand.self
            )
            self.resume = try Self.loadSymbol(
                "tryagi_libtorrent_job_resume",
                from: dynamicLibraryHandle,
                missingSymbols: &missingSymbols,
                as: NativeJSONCommand.self
            )
            self.cancel = try Self.loadSymbol(
                "tryagi_libtorrent_job_cancel",
                from: dynamicLibraryHandle,
                missingSymbols: &missingSymbols,
                as: NativeJSONCommand.self
            )
            self.lastError = try Self.loadSymbol(
                "tryagi_libtorrent_last_error",
                from: dynamicLibraryHandle,
                missingSymbols: &missingSymbols,
                as: NativeLastError.self
            )
        }

        private static func loadSymbol<T>(
            _ name: String,
            from handle: UnsafeMutableRawPointer,
            missingSymbols: inout [String],
            as _: T.Type
        ) throws -> T {
            guard let symbol = dlsym(handle, name) else {
                missingSymbols.append(name)
                throw LibtorrentRuntimeError.missingNativeSymbol(name)
            }
            return unsafeBitCast(symbol, to: T.self)
        }

        private static func loadOptionalSymbol<T>(
            _ name: String,
            from handle: UnsafeMutableRawPointer,
            as _: T.Type
        ) -> T? {
            guard let symbol = dlsym(handle, name) else {
                return nil
            }
            return unsafeBitCast(symbol, to: T.self)
        }

        private static func dynamicLibraryCandidates() -> [NativeLibtorrentDynamicLibraryCandidate] {
            var candidates: [NativeLibtorrentDynamicLibraryCandidate] = [.currentProcess]

            let frameworkRelativePath = "LibtorrentNative.framework/LibtorrentNative"
            let bundlePaths = [
                Bundle.main.privateFrameworksPath,
                Bundle.main.sharedFrameworksPath,
                Bundle.main.builtInPlugInsPath,
                Bundle.main.bundlePath.appending("/Frameworks"),
            ]

            for bundlePath in bundlePaths.compactMap(\.self) {
                candidates.append(.path("\(bundlePath)/\(frameworkRelativePath)"))
            }

            candidates.append(.path(frameworkRelativePath))
            candidates.append(.path("libLibtorrentNative.dylib"))
            return candidates
        }
    }

    private struct NativeLibtorrentStartRequest: Encodable {
        let input: LibtorrentJobInput
        let selection: LibtorrentFileSelection?
    }

    private struct NativeLibtorrentSelectionRequest: Encodable {
        let jobId: UUID
        let selection: LibtorrentFileSelection
    }

    private struct NativeLibtorrentRateLimitsRequest: Encodable {
        let jobId: UUID
        let downloadBytesPerSecond: Int
        let uploadBytesPerSecond: Int

        init(jobId: UUID, rateLimits: LibtorrentRateLimits) {
            self.jobId = jobId
            self.downloadBytesPerSecond = rateLimits.downloadBytesPerSecond ?? 0
            self.uploadBytesPerSecond = rateLimits.uploadBytesPerSecond ?? 0
        }
    }

    private struct NativeLibtorrentJobControlRequest: Encodable {
        let jobId: UUID
    }

    private struct NativeLibtorrentEventPayload: Decodable {
        let type: String
        let progress: LibtorrentProgress?
        let readiness: LibtorrentStreamReadiness?

        func event() throws -> LibtorrentEvent {
            switch type.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "-", with: "_").lowercased() {
            case "progress":
                guard let progress else {
                    throw LibtorrentRuntimeError.invalidNativeEvent("progress event is missing progress payload")
                }
                return .progress(progress)
            case "completed", "complete":
                guard let progress else {
                    throw LibtorrentRuntimeError.invalidNativeEvent("completed event is missing progress payload")
                }
                return .completed(progress)
            case "stream_ready":
                guard let readiness else {
                    throw LibtorrentRuntimeError.invalidNativeEvent("stream_ready event is missing readiness payload")
                }
                return .streamReady(readiness)
            default:
                throw LibtorrentRuntimeError.invalidNativeEvent("unsupported event type '\(type)'")
            }
        }
    }

    private final class NativeLibtorrentEventBridge: @unchecked Sendable {
        private let stateLock = NSLock()
        private var handler: (@Sendable (LibtorrentEvent) -> Void)?
        private let decoder = JSONDecoder()

        func install(_ handler: @escaping @Sendable (LibtorrentEvent) -> Void) {
            stateLock.lock()
            self.handler = handler
            stateLock.unlock()
        }

        func receive(json: String) {
            guard let data = json.data(using: .utf8),
                  let event = try? decoder.decode(NativeLibtorrentEventPayload.self, from: data).event()
            else {
                return
            }

            stateLock.lock()
            let handler = handler
            stateLock.unlock()
            handler?(event)
        }
    }

    private enum NativeLibtorrentDynamicLibraryCandidate {
        case currentProcess
        case path(String)

        var shouldClose: Bool {
            switch self {
            case .currentProcess:
                false
            case .path:
                true
            }
        }

        func open() -> UnsafeMutableRawPointer? {
            switch self {
            case .currentProcess:
                dlopen(nil, RTLD_NOW)
            case let .path(path):
                dlopen(path, RTLD_NOW | RTLD_LOCAL)
            }
        }
    }

    private let nativeEventCallback: NativeLibtorrentLibrary.NativeEventCallback = { rawJSON, rawContext in
        guard let rawJSON,
              let rawContext
        else {
            return
        }

        let bridge = Unmanaged<NativeLibtorrentEventBridge>.fromOpaque(rawContext).takeUnretainedValue()
        bridge.receive(json: String(cString: rawJSON))
    }

    private extension LibtorrentEvent {
        var jobId: UUID {
            switch self {
            case let .progress(progress), let .completed(progress):
                progress.jobId
            case let .streamReady(readiness):
                readiness.jobId
            }
        }
    }
#endif
