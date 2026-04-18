import Foundation

final class OpenAIService: AIImageService {
    let name = "OpenAI"
    private var activeTask: URLSessionTask?

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 300
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config)
    }()

    var isConfigured: Bool {
        KeychainManager.shared.getAPIKey(for: .openAI) != nil
    }

    private var apiKey: String? {
        KeychainManager.shared.getAPIKey(for: .openAI)
    }

    // MARK: - Sketch-to-image via Responses API

    func transform(sketch image: Data, prompt: String, style: AIStyle?, quality: AIQuality) async throws -> [AIGeneratedImage] {
        guard let apiKey = apiKey else { throw AIServiceError.notConfigured(service: name) }

        let fullPrompt = AIPromptBuilder.buildPrompt(
            userPrompt: prompt,
            style: style ?? .photorealistic
        )

        let base64Image = image.base64EncodedString()

        // Use the Responses API with image_generation tool
        let requestBody: [String: Any] = [
            "model": "gpt-4o-mini",
            "input": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "input_image",
                            "image_url": "data:image/png;base64,\(base64Image)"
                        ],
                        [
                            "type": "input_text",
                            "text": fullPrompt
                        ]
                    ]
                ]
            ],
            "tools": [
                [
                    "type": "image_generation",
                    "size": "1024x1024"
                ]
            ]
        ]

        return try await makeResponsesRequest(apiKey: apiKey, body: requestBody, prompt: fullPrompt)
    }

    // MARK: - Text-to-image via Responses API

    func generate(prompt: String, style: AIStyle?, quality: AIQuality, size: AIImageSize) async throws -> [AIGeneratedImage] {
        guard let apiKey = apiKey else { throw AIServiceError.notConfigured(service: name) }

        let fullPrompt = AIPromptBuilder.buildPrompt(
            userPrompt: prompt,
            style: style ?? .photorealistic,
            preserveComposition: false
        )

        let requestBody: [String: Any] = [
            "model": "gpt-4o-mini",
            "input": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "input_text",
                            "text": fullPrompt
                        ]
                    ]
                ]
            ],
            "tools": [
                [
                    "type": "image_generation",
                    "size": size.rawValue
                ]
            ]
        ]

        return try await makeResponsesRequest(apiKey: apiKey, body: requestBody, prompt: fullPrompt)
    }

    func cancel() {
        activeTask?.cancel()
        activeTask = nil
    }

    // MARK: - Shared Responses API request

    private func makeResponsesRequest(apiKey: String, body: [String: Any], prompt: String) async throws -> [AIGeneratedImage] {
        let url = URL(string: "https://api.openai.com/v1/responses")!

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        try checkHTTPResponse(response, data: data)

        return try parseResponsesOutput(data: data, prompt: prompt)
    }

    // MARK: - Parse Responses API output

    private func parseResponsesOutput(data: Data, prompt: String) throws -> [AIGeneratedImage] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let output = json["output"] as? [[String: Any]] else {
            throw AIServiceError.invalidResponse
        }

        var images: [AIGeneratedImage] = []

        for item in output {
            let type = item["type"] as? String

            if type == "image_generation_call",
               let result = item["result"] as? String,
               let imageData = Data(base64Encoded: result) {
                // Direct base64 image in result
                images.append(AIGeneratedImage(
                    imageData: imageData,
                    prompt: prompt,
                    service: "openai",
                    model: "gpt-image-1"
                ))
            }

            // Also check for inline image content
            if type == "message",
               let content = item["content"] as? [[String: Any]] {
                for c in content {
                    if c["type"] as? String == "image",
                       let b64 = c["data"] as? String,
                       let imageData = Data(base64Encoded: b64) {
                        images.append(AIGeneratedImage(
                            imageData: imageData,
                            prompt: prompt,
                            service: "openai",
                            model: "gpt-image-1"
                        ))
                    }
                }
            }
        }

        guard !images.isEmpty else {
            // Check if there's a text response explaining why no image was generated
            for item in output {
                if let content = item["content"] as? [[String: Any]] {
                    for c in content {
                        if let text = c["text"] as? String, !text.isEmpty {
                            throw AIServiceError.contentFiltered(reason: text)
                        }
                    }
                }
            }
            throw AIServiceError.invalidResponse
        }

        return images
    }

    // MARK: - Error Handling

    private func checkHTTPResponse(_ response: URLResponse, data: Data) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AIServiceError.invalidResponse
        }

        switch httpResponse.statusCode {
        case 200...299:
            return
        case 401:
            throw AIServiceError.invalidAPIKey(service: name)
        case 429:
            throw AIServiceError.rateLimited(retryAfter: 30)
        case 400:
            let msg = parseErrorMessage(data: data)
            if msg.lowercased().contains("safety") || msg.lowercased().contains("content policy") {
                throw AIServiceError.contentFiltered(reason: msg)
            }
            throw AIServiceError.serverError(statusCode: 400, message: msg)
        default:
            throw AIServiceError.serverError(statusCode: httpResponse.statusCode, message: parseErrorMessage(data: data))
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
