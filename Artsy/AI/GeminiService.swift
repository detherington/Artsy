import Foundation

final class GeminiService: AIImageService {
    let name = "Google"

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config)
    }()

    var isConfigured: Bool {
        KeychainManager.shared.getAPIKey(for: .google) != nil
    }

    private var apiKey: String? {
        KeychainManager.shared.getAPIKey(for: .google)
    }

    // Gemini Native Image — works for both sketch-to-image and text-to-image
    func transform(sketch image: Data, prompt: String, style: AIStyle?, quality: AIQuality) async throws -> [AIGeneratedImage] {
        guard let apiKey = apiKey else { throw AIServiceError.notConfigured(service: name) }

        let fullPrompt = AIPromptBuilder.buildPrompt(
            userPrompt: prompt,
            style: style ?? .photorealistic
        )

        let model = modelForQuality(quality)
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!

        let requestBody: [String: Any] = [
            "contents": [[
                "parts": [
                    ["inlineData": ["mimeType": "image/png", "data": image.base64EncodedString()]],
                    ["text": fullPrompt]
                ]
            ]],
            "generationConfig": [
                "responseModalities": ["TEXT", "IMAGE"]
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        do {
            let (data, response) = try await session.data(for: request)
            try checkHTTPResponse(response, data: data)
            return try parseGeminiResponse(data: data, prompt: fullPrompt, model: model)
        } catch let error as URLError where error.code == .timedOut {
            // Retry once with the fastest model
            let fallback = "gemini-2.5-flash-image"
            if model != fallback {
                return try await makeRequest(
                    apiKey: apiKey, model: fallback, prompt: fullPrompt,
                    parts: [
                        ["inlineData": ["mimeType": "image/png", "data": image.base64EncodedString()]],
                        ["text": fullPrompt]
                    ]
                )
            }
            throw AIServiceError.networkError(underlying: error)
        }
    }

    // Text-to-image using Gemini native
    func generate(prompt: String, style: AIStyle?, quality: AIQuality, size: AIImageSize) async throws -> [AIGeneratedImage] {
        guard let apiKey = apiKey else { throw AIServiceError.notConfigured(service: name) }

        let fullPrompt = AIPromptBuilder.buildPrompt(
            userPrompt: prompt,
            style: style ?? .photorealistic,
            preserveComposition: false
        )

        let model = modelForQuality(quality)
        return try await makeRequest(
            apiKey: apiKey, model: model, prompt: fullPrompt,
            parts: [["text": fullPrompt]]
        )
    }

    /// Shared request method with timeout retry
    private func makeRequest(
        apiKey: String, model: String, prompt: String,
        parts: [[String: Any]]
    ) async throws -> [AIGeneratedImage] {
        let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!

        let requestBody: [String: Any] = [
            "contents": [["parts": parts]],
            "generationConfig": [
                "responseModalities": ["TEXT", "IMAGE"]
            ]
        ]

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try JSONSerialization.data(withJSONObject: requestBody)

        do {
            let (data, response) = try await session.data(for: request)
            try checkHTTPResponse(response, data: data)
            return try parseGeminiResponse(data: data, prompt: prompt, model: model)
        } catch let error as URLError where error.code == .timedOut {
            throw AIServiceError.networkError(underlying: error)
        }
    }

    func cancel() {}

    // MARK: - Model Selection

    private func modelForQuality(_ quality: AIQuality) -> String {
        switch quality {
        case .low: return "gemini-2.5-flash-image"
        case .medium: return "gemini-3.1-flash-image-preview"
        case .high: return "gemini-3-pro-image-preview"
        }
    }

    // MARK: - Response Parsing

    private func parseGeminiResponse(data: Data, prompt: String, model: String) throws -> [AIGeneratedImage] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let candidates = json["candidates"] as? [[String: Any]] else {
            // Try to get error message
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let error = json["error"] as? [String: Any],
               let message = error["message"] as? String {
                throw AIServiceError.serverError(statusCode: 0, message: message)
            }
            throw AIServiceError.invalidResponse
        }

        var images: [AIGeneratedImage] = []

        for candidate in candidates {
            guard let content = candidate["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]] else { continue }

            for part in parts {
                if let inlineData = part["inlineData"] as? [String: Any],
                   let b64 = inlineData["data"] as? String,
                   let mimeType = inlineData["mimeType"] as? String,
                   mimeType.starts(with: "image/"),
                   let imageData = Data(base64Encoded: b64) {
                    images.append(AIGeneratedImage(
                        imageData: imageData,
                        prompt: prompt,
                        service: "google",
                        model: model
                    ))
                }
            }
        }

        guard !images.isEmpty else {
            // Check if there's text-only response (model refused to generate image)
            for candidate in candidates {
                if let content = candidate["content"] as? [String: Any],
                   let parts = content["parts"] as? [[String: Any]] {
                    for part in parts {
                        if let text = part["text"] as? String, !text.isEmpty {
                            throw AIServiceError.contentFiltered(reason: text)
                        }
                    }
                }
            }
            throw AIServiceError.invalidResponse
        }
        return images
    }

    private func checkHTTPResponse(_ response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIServiceError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200...299: return
        case 401, 403:
            throw AIServiceError.invalidAPIKey(service: name)
        case 429:
            throw AIServiceError.rateLimited(retryAfter: 30)
        case 503:
            throw AIServiceError.serverError(statusCode: 503, message: "Model temporarily unavailable. Try a different quality level or try again shortly.")
        default:
            let msg = parseErrorMessage(data: data)
            throw AIServiceError.serverError(statusCode: httpResponse.statusCode, message: msg)
        }
    }

    private func parseErrorMessage(data: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] as? [String: Any],
           let message = error["message"] as? String {
            return message
        }
        return String(data: data, encoding: .utf8) ?? "Unknown error"
    }
}
