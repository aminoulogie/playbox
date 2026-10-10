import Foundation
import Combine

/// Downloads direct (http/https) streams to Documents/Downloads so they show up
/// in the Files app (needs UIFileSharingEnabled + LSSupportsOpeningDocumentsInPlace).
final class DownloadManager: NSObject, ObservableObject, URLSessionDownloadDelegate {
    enum State: Equatable {
        case downloading
        case finished(URL)
        case failed(String)
    }

    struct Job: Identifiable, Equatable {
        let id: String
        let name: String
        var progress: Double
        var state: State
    }

    @Published private(set) var jobs: [String: Job] = [:]

    private var session: URLSession!
    private var running: [String: URLSessionDownloadTask] = [:]
    private var names: [String: String] = [:]
    private let lock = NSLock()

    override init() {
        super.init()
        session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
    }

    // MARK: - Public API

    func start(id: String, url: URL, name: String) {
        if case .downloading? = jobs[id]?.state { return }

        let task = session.downloadTask(with: url)
        task.taskDescription = id

        lock.lock()
        names[id] = name
        running[id] = task
        lock.unlock()

        jobs[id] = Job(id: id, name: name, progress: 0, state: .downloading)
        task.resume()
    }

    func cancel(id: String) {
        lock.lock()
        let task = running.removeValue(forKey: id)
        names.removeValue(forKey: id)
        lock.unlock()

        task?.cancel()
        jobs[id] = nil
    }

    func retry(id: String, url: URL, name: String) {
        start(id: id, url: url, name: name)
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard let id = downloadTask.taskDescription, totalBytesExpectedToWrite > 0 else { return }

        let value = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        DispatchQueue.main.async {
            guard var job = self.jobs[id], case .downloading = job.state else { return }
            job.progress = min(max(value, 0), 1)
            self.jobs[id] = job
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let id = downloadTask.taskDescription else { return }

        if let http = downloadTask.response as? HTTPURLResponse,
           !(200..<300).contains(http.statusCode) {
            fail(id, "Server returned HTTP \(http.statusCode)")
            cleanup(id)
            return
        }

        lock.lock()
        let name = names[id] ?? "Video"
        lock.unlock()

        let ext = fileExtension(for: downloadTask)

        do {
            let folder = try FileManager.default
                .url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("Downloads", isDirectory: true)

            try FileManager.default.createDirectory(
                at: folder,
                withIntermediateDirectories: true
            )

            let base = Self.sanitize(name)
            var destination = folder.appendingPathComponent("\(base).\(ext)")
            var counter = 2

            while FileManager.default.fileExists(atPath: destination.path) {
                destination = folder.appendingPathComponent("\(base) (\(counter)).\(ext)")
                counter += 1
            }

            // The temporary file is deleted when this callback returns, so move it now.
            try FileManager.default.moveItem(at: location, to: destination)

            DispatchQueue.main.async {
                guard var job = self.jobs[id] else { return }
                job.progress = 1
                job.state = .finished(destination)
                self.jobs[id] = job
            }
        } catch {
            fail(id, error.localizedDescription)
        }

        cleanup(id)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error, let id = task.taskDescription else { return }

        if (error as NSError).code == NSURLErrorCancelled {
            cleanup(id)
            return
        }

        fail(id, error.localizedDescription)
        cleanup(id)
    }

    // MARK: - Helpers

    private func fail(_ id: String, _ message: String) {
        DispatchQueue.main.async {
            guard var job = self.jobs[id] else { return }
            job.state = .failed(message)
            self.jobs[id] = job
        }
    }

    private func cleanup(_ id: String) {
        lock.lock()
        running.removeValue(forKey: id)
        names.removeValue(forKey: id)
        lock.unlock()
    }

    private func fileExtension(for task: URLSessionDownloadTask) -> String {
        let urlExtension = task.originalRequest?.url?.pathExtension ?? ""
        if Self.isValidFileExtension(urlExtension) {
            return urlExtension.lowercased()
        }

        let suggestedExtension = task.response?.suggestedFilename\n            .map { ($0 as NSString).pathExtension } ?? ""
        if Self.isValidFileExtension(suggestedExtension) {
            return suggestedExtension.lowercased()
        }

        return "mp4"
    }

    private static func isValidFileExtension(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 8 else { return false }
        return value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0)
        }
    }

    private static func sanitize(_ value: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = value
            .components(separatedBy: invalidCharacters)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return cleaned.isEmpty ? "Video" : String(cleaned.prefix(120))
    }
}
