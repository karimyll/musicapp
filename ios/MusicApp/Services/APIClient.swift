import Foundation

struct SearchResult: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let artist: String
    let album: String?
    let duration: Double?
    let thumbnail: String?
}

struct AlbumResult: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let artist: String
    let year: String?
    let thumbnail: String?
}

/// An album or playlist from YouTube Music.
struct RemoteCollection: Codable {
    let title: String
    let author: String
    let year: String?
    let thumbnail: String?
    let tracks: [SearchResult]
}

struct APIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct APIClient {
    let baseURL: URL
    let token: String

    var authHeaders: [String: String] { ["Authorization": "Bearer \(token)"] }

    private func request(_ path: String, query: [URLQueryItem] = [], timeout: TimeInterval = 30) -> URLRequest {
        var comps = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!, timeoutInterval: timeout)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return req
    }

    private func get<T: Decodable>(_ path: String, _ query: [URLQueryItem] = [], timeout: TimeInterval = 30) async throws -> T {
        let (data, resp) = try await URLSession.shared.data(for: request(path, query: query, timeout: timeout))
        try Self.check(resp, data: data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    func search(_ q: String) async throws -> [SearchResult] {
        try await get("search", [.init(name: "q", value: q), .init(name: "limit", value: "25")])
    }

    func searchAlbums(_ q: String) async throws -> [AlbumResult] {
        try await get("search", [.init(name: "q", value: q), .init(name: "limit", value: "20"), .init(name: "type", value: "albums")])
    }

    func album(_ id: String) async throws -> RemoteCollection {
        try await get("album/\(id)")
    }

    func importLink(_ url: String) async throws -> RemoteCollection {
        try await get("playlist", [.init(name: "url", value: url)], timeout: 60)
    }

    /// Songs similar to `id` (YouTube Music radio), used for Autoplay.
    func radio(_ id: String) async throws -> [SearchResult] {
        try await get("radio/\(id)", [.init(name: "limit", value: "25")])
    }

    func health() async throws -> String {
        struct H: Decodable { let yt_dlp: String }
        let h: H = try await get("health")
        return h.yt_dlp
    }

    /// The server fetches from YouTube first, so the first byte can take a while.
    func audioRequest(id: String) -> URLRequest {
        request("audio/\(id)", timeout: 300)
    }

    func audioURL(id: String) -> URL { baseURL.appending(path: "audio/\(id)") }

    static func check(_ resp: URLResponse, data: Data?) throws {
        guard let http = resp as? HTTPURLResponse else { throw APIError(message: "No response from server") }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw APIError(message: "Wrong token (401)") }
            struct Detail: Decodable { let detail: String }
            let detail = data.flatMap { try? JSONDecoder().decode(Detail.self, from: $0).detail }
            throw APIError(message: detail ?? "Server error (\(http.statusCode))")
        }
    }
}
