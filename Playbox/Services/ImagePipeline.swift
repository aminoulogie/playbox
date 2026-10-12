import CryptoKit
import ImageIO
import SwiftUI
import UIKit

/// Memory + disk poster cache. Images are decoded and downsampled off the main
/// thread to the size they are drawn at, so scrolling never decodes full-size
/// JPEGs and revisited posters appear instantly.
actor ImagePipeline {
    static let shared = ImagePipeline()

    private let memory = MemoryImageCache()
    private var inFlight: [String: Task<UIImage?, Never>] = [:]
    private let directory: URL
    private let session: URLSession

    init() {
        directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PosterCache", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configuration = URLSessionConfiguration.default
        configuration.requestCachePolicy = .returnCacheDataElseLoad
        configuration.urlCache = nil
        configuration.httpMaximumConnectionsPerHost = 8
        configuration.timeoutIntervalForRequest = 20
        session = URLSession(configuration: configuration)
    }

    nonisolated func cachedImage(for url: URL, maxPixel: Int) -> UIImage? {
        memory.image(for: Self.memoryKey(url, maxPixel))
    }

    func image(for url: URL, maxPixel: Int) async -> UIImage? {
        let key = Self.memoryKey(url, maxPixel)
        if let hit = memory.image(for: key) { return hit }
        if let running = inFlight[key] { return await running.value }

        let file = directory.appendingPathComponent(Self.diskName(url))
        let session = session
        let task = Task.detached(priority: .userInitiated) { () -> UIImage? in
            if let data = try? Data(contentsOf: file) {
                return Self.downsample(data, maxPixel: maxPixel)
            }
            guard let result = try? await session.data(from: url) else { return nil }
            if let http = result.1 as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                return nil
            }
            try? result.0.write(to: file, options: .atomic)
            return Self.downsample(result.0, maxPixel: maxPixel)
        }
        inFlight[key] = task
        let image = await task.value
        inFlight[key] = nil
        if let image {
            memory.store(image, for: key)
        }
        return image
    }

    private nonisolated static func downsample(_ data: Data, maxPixel: Int) -> UIImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, options) else { return nil }
        let thumbnailOptions = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixel),
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else { return nil }
        return UIImage(cgImage: image)
    }

    private nonisolated static func memoryKey(_ url: URL, _ maxPixel: Int) -> String {
        "\(maxPixel)|\(url.absoluteString)"
    }

    private nonisolated static func diskName(_ url: URL) -> String {
        let digest = SHA256.hash(data: Data(url.absoluteString.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

final class MemoryImageCache: @unchecked Sendable {
    private let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 96 * 1024 * 1024
        return cache
    }()

    func image(for key: String) -> UIImage? {
        cache.object(forKey: key as NSString)
    }

    func store(_ image: UIImage, for key: String) {
        let cost = Int(image.size.width * image.size.height * image.scale * image.scale * 4)
        cache.setObject(image, forKey: key as NSString, cost: cost)
    }
}

/// Drop-in replacement for `AsyncImage` that uses `ImagePipeline`.
struct CachedImage<Placeholder: View>: View {
    let url: URL?
    /// Largest drawn dimension in points; the pipeline scales it by the screen scale.
    var maxPoints: CGFloat = 400
    @ViewBuilder var placeholder: () -> Placeholder

    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    @State private var loadedURL: URL?

    var body: some View {
        Group {
            if let image, loadedURL == url {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                placeholder()
            }
        }
        .task(id: url) {
            guard let url else { image = nil; loadedURL = nil; return }
            let maxPixel = Self.bucket(maxPoints * displayScale)
            if let hit = ImagePipeline.shared.cachedImage(for: url, maxPixel: maxPixel) {
                image = hit
                loadedURL = url
                return
            }
            let loaded = await ImagePipeline.shared.image(for: url, maxPixel: maxPixel)
            guard !Task.isCancelled else { return }
            image = loaded
            loadedURL = url
        }
    }

    /// Round up so small layout changes reuse the same cached bitmap.
    private static func bucket(_ pixels: CGFloat) -> Int {
        let step: CGFloat = 128
        return Int((max(pixels, step) / step).rounded(.up) * step)
    }
}
