import Foundation

enum AddonError: LocalizedError {
    case invalidURL
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "Invalid add-on URL."
        case .invalidResponse: return "The add-on returned an invalid response."
        }
    }
}

struct AddonClient {
    private let decoder = JSONDecoder()

    /// Shared session: keeps HTTP/2 connections to add-ons alive between
    /// requests and honours add-on cache headers for catalogs and metadata.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.urlCache = URLCache(
            memoryCapacity: 16 * 1024 * 1024,
            diskCapacity: 128 * 1024 * 1024
        )
        configuration.requestCachePolicy = .useProtocolCachePolicy
        configuration.timeoutIntervalForRequest = 15
        configuration.httpMaximumConnectionsPerHost = 8
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    func manifest(baseURL: URL) async throws -> AddonManifest {
        try await get(baseURL.appendingPathComponent("manifest.json"))
    }

    func catalog(baseURL: URL, type: String, id: String) async throws -> [MetaPreview] {
        let value: CatalogResponse = try await get(
            baseURL.appendingPathComponent("catalog")
                .appendingPathComponent(type)
                .appendingPathComponent(id + ".json")
        )
        return value.metas
    }

    func search(baseURL: URL, type: String, catalogID: String = "top", query: String) async throws -> [MetaPreview] {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("catalog")
                .appendingPathComponent(type)
                .appendingPathComponent(catalogID)
                .appendingPathComponent("search=" + query + ".json"),
            resolvingAgainstBaseURL: false
        )
        guard let url = components?.url else { throw AddonError.invalidURL }
        let value: CatalogResponse = try await get(url)
        return value.metas
    }

    func meta(baseURL: URL, type: String, id: String) async throws -> MetaPreview {
        let value: MetaResponse = try await get(
            baseURL.appendingPathComponent("meta")
                .appendingPathComponent(type)
                .appendingPathComponent(id + ".json")
        )
        return value.meta
    }

    func subtitles(baseURL: URL, type: String, id: String) async throws -> [AddonSubtitle] {
        let value: SubtitleResponse = try await get(
            baseURL.appendingPathComponent("subtitles")
                .appendingPathComponent(type)
                .appendingPathComponent(id + ".json")
        )
        return value.subtitles
    }

    func streams(baseURL: URL, type: String, id: String) async throws -> [AddonStream] {
        let value: StreamResponse = try await get(
            baseURL.appendingPathComponent("stream")
                .appendingPathComponent(type)
                .appendingPathComponent(id + ".json")
        )
        return value.streams
    }

    private func get<T: Decodable>(_ url: URL) async throws -> T {
        let (data, response) = try await Self.session.data(from: url)
        guard let http = response as? HTTPURLResponse,
              200..<300 ~= http.statusCode else { throw AddonError.invalidResponse }
        return try decoder.decode(T.self, from: data)
    }
}
