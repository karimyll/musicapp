import Foundation

struct SearchResult: Codable, Identifiable, Hashable {
    let id: String
    let title: String
    let artist: String
    let album: String?
    let duration: Double?
    let thumbnail: String?
}

struct APIError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

struct APIClient {
    let baseURL: URL
    let token: String

    private func request(_ path: String, query: [URLQueryItem] = [], timeout: TimeInterval = 30) -> URLRequest {
        var comps = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { comps.queryItems = query }
        var req = URLRequest(url: comps.url!, timeoutInterval: timeout)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return req
    }

    func search(_ q: String) async throws -> [SearchResult] {
        let req = request("search", query: [URLQueryItem(name: "q", value: q), URLQueryItem(name: "limit", value: "25")])
        let (data, resp) = try await URLSession.shared.data(for: req)
        try Self.check(resp, data: data)
        return try JSONDecoder().decode([SearchResult].self, from: data)
    }

    func health() async throws -> String {
        let (data, resp) = try await URLSession.shared.data(for: request("health"))
        try Self.check(resp, data: data)
        struct H: Decodable { let yt_dlp: String }
        return try JSONDecoder().decode(H.self, from: data).yt_dlp
    }

    /// The server fetches from YouTube first, so the first byte can take a while.
    func audioRequest(id: String) -> URLRequest {
        request("audio/\(id)", timeout: 300)
    }

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
