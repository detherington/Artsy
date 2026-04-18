import Foundation

// MARK: - Data Models

struct UnsplashPhoto: Identifiable, Decodable {
    let id: String
    let description: String?
    let altDescription: String?
    let urls: PhotoURLs
    let user: User
    let links: PhotoLinks

    struct PhotoURLs: Decodable {
        let raw: String
        let full: String
        let regular: String
        let small: String
        let thumb: String
    }

    struct User: Decodable {
        let name: String
        let username: String
        let links: UserLinks

        struct UserLinks: Decodable {
            let html: String
        }
    }

    struct PhotoLinks: Decodable {
        let html: String
        let download: String
        let downloadLocation: String

        enum CodingKeys: String, CodingKey {
            case html
            case download
            case downloadLocation = "download_location"
        }
    }

    enum CodingKeys: String, CodingKey {
        case id
        case description
        case altDescription = "alt_description"
        case urls
        case user
        case links
    }
}

struct UnsplashSearchResponse: Decodable {
    let total: Int
    let totalPages: Int
    let results: [UnsplashPhoto]

    enum CodingKeys: String, CodingKey {
        case total
        case totalPages = "total_pages"
        case results
    }
}

enum UnsplashDownloadSize: String, CaseIterable, Identifiable {
    case small = "Small"
    case regular = "Regular"
    case full = "Full"

    var id: String { rawValue }

    func url(from urls: UnsplashPhoto.PhotoURLs) -> String {
        switch self {
        case .small: return urls.small
        case .regular: return urls.regular
        case .full: return urls.full
        }
    }

    var description: String {
        switch self {
        case .small: return "Small (400px)"
        case .regular: return "Regular (1080px)"
        case .full: return "Full"
        }
    }
}

enum UnsplashError: LocalizedError {
    case notConfigured
    case invalidAPIKey
    case rateLimited
    case serverError(statusCode: Int, message: String)
    case networkError(underlying: Error)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Unsplash API key not configured. Add it in Settings."
        case .invalidAPIKey: return "Unsplash API key is invalid."
        case .rateLimited: return "Rate limited. Try again shortly."
        case .serverError(let code, let msg): return "Unsplash error (\(code)): \(msg)"
        case .networkError(let err): return "Network error: \(err.localizedDescription)"
        case .invalidResponse: return "Invalid response from Unsplash"
        }
    }
}

// MARK: - Service

final class UnsplashService {
    static let shared = UnsplashService()

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 300
        return URLSession(configuration: config)
    }()

    var isConfigured: Bool {
        KeychainManager.shared.getAPIKey(for: .unsplash) != nil
    }

    private var apiKey: String? {
        KeychainManager.shared.getAPIKey(for: .unsplash)
    }

    // MARK: - Search

    func search(query: String, page: Int = 1, perPage: Int = 20) async throws -> [UnsplashPhoto] {
        guard let key = apiKey else { throw UnsplashError.notConfigured }
        guard var components = URLComponents(string: "https://api.unsplash.com/search/photos") else {
            throw UnsplashError.invalidResponse
        }

        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "page", value: "\(page)"),
            URLQueryItem(name: "per_page", value: "\(perPage)")
        ]

        guard let url = components.url else { throw UnsplashError.invalidResponse }

        var request = URLRequest(url: url)
        request.setValue("Client-ID \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("v1", forHTTPHeaderField: "Accept-Version")

        let (data, response) = try await session.data(for: request)
        try checkHTTPResponse(response, data: data)

        let decoded = try JSONDecoder().decode(UnsplashSearchResponse.self, from: data)
        return decoded.results
    }

    // MARK: - Download

    /// Download image bytes at the chosen size. Also triggers the Unsplash download-tracking
    /// endpoint as required by the API TOS.
    func downloadPhoto(_ photo: UnsplashPhoto, size: UnsplashDownloadSize) async throws -> Data {
        // Fire download-tracking endpoint (required per Unsplash TOS)
        trackDownload(photo: photo)

        // Download the image from the chosen URL
        guard let url = URL(string: size.url(from: photo.urls)) else {
            throw UnsplashError.invalidResponse
        }

        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw UnsplashError.serverError(statusCode: http.statusCode, message: "Image download failed")
        }
        return data
    }

    /// Fire-and-forget download tracking (per Unsplash API TOS).
    private func trackDownload(photo: UnsplashPhoto) {
        guard let key = apiKey,
              let url = URL(string: photo.links.downloadLocation) else { return }
        var request = URLRequest(url: url)
        request.setValue("Client-ID \(key)", forHTTPHeaderField: "Authorization")
        let task = session.dataTask(with: request) { _, _, _ in }
        task.resume()
    }

    // MARK: - Response Handling

    private func checkHTTPResponse(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw UnsplashError.invalidResponse
        }
        switch http.statusCode {
        case 200...299: return
        case 401, 403: throw UnsplashError.invalidAPIKey
        case 429: throw UnsplashError.rateLimited
        default:
            let msg = parseErrorMessage(data: data)
            throw UnsplashError.serverError(statusCode: http.statusCode, message: msg)
        }
    }

    private func parseErrorMessage(data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let errors = json["errors"] as? [String] {
                return errors.joined(separator: ", ")
            }
            if let message = json["error"] as? String { return message }
        }
        return String(data: data, encoding: .utf8) ?? "Unknown error"
    }
}
