import Foundation

protocol AIImageService {
    var name: String { get }
    var isConfigured: Bool { get }

    func transform(
        sketch image: Data,
        prompt: String,
        style: AIStyle?,
        quality: AIQuality
    ) async throws -> [AIGeneratedImage]

    func generate(
        prompt: String,
        style: AIStyle?,
        quality: AIQuality,
        size: AIImageSize
    ) async throws -> [AIGeneratedImage]

    func cancel()
}

struct AIGeneratedImage: Identifiable {
    let id: UUID
    let imageData: Data
    let prompt: String
    let revisedPrompt: String?
    let service: String
    let model: String
    let timestamp: Date

    init(id: UUID = UUID(), imageData: Data, prompt: String, revisedPrompt: String? = nil, service: String, model: String) {
        self.id = id
        self.imageData = imageData
        self.prompt = prompt
        self.revisedPrompt = revisedPrompt
        self.service = service
        self.model = model
        self.timestamp = Date()
    }
}

enum AIQuality: String, CaseIterable, Identifiable {
    case low
    case medium
    case high

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .low: return "Low (Fast)"
        case .medium: return "Medium"
        case .high: return "High (Best)"
        }
    }
}

enum AIImageSize: String, CaseIterable, Identifiable {
    case square = "1024x1024"
    case landscape = "1536x1024"
    case portrait = "1024x1536"

    var id: String { rawValue }
}

enum AIStyle: String, CaseIterable, Codable, Identifiable {
    case photorealistic = "Photorealistic"
    case oilPainting = "Oil Painting"
    case watercolor = "Watercolor"
    case digitalArt = "Digital Art"
    case anime = "Anime / Manga"
    case pencilSketch = "Detailed Pencil Sketch"
    case comicBook = "Comic Book"
    case pixelArt = "Pixel Art"
    case impressionist = "Impressionist"
    case minimalist = "Minimalist"
    case sciFiConcept = "Sci-Fi Concept Art"
    case fantasy = "Fantasy Illustration"
    case architecturalRender = "Architectural Render"
    case custom = "Custom"

    var id: String { rawValue }

    var promptPrefix: String {
        switch self {
        case .photorealistic:
            return "Transform this sketch into a photorealistic image with natural lighting, realistic materials, and fine detail."
        case .oilPainting:
            return "Transform this sketch into a rich oil painting with visible brushwork, deep colors, and classical technique."
        case .watercolor:
            return "Transform this sketch into a delicate watercolor painting with soft washes, color bleeding, and paper texture."
        case .digitalArt:
            return "Transform this sketch into polished digital art with clean lines, vibrant colors, and modern technique."
        case .anime:
            return "Transform this sketch into Japanese animation style art with clean cel shading, bold ink outlines, flat color areas, and vibrant palette."
        case .pencilSketch:
            return "Transform this sketch into a highly detailed pencil drawing with realistic shading, cross-hatching, and fine graphite texture."
        case .comicBook:
            return "Transform this sketch into comic book style art with bold ink lines, halftone shading, and dynamic composition."
        case .pixelArt:
            return "Transform this sketch into pixel art with a retro game aesthetic, limited palette, and clean pixel placement."
        case .impressionist:
            return "Transform this sketch into an impressionist painting with visible brushstrokes, light-focused color, and atmospheric quality."
        case .minimalist:
            return "Transform this sketch into minimalist art with clean geometry, limited palette, and elegant simplicity."
        case .sciFiConcept:
            return "Transform this sketch into sci-fi concept art with futuristic technology, dramatic lighting, and cinematic atmosphere."
        case .fantasy:
            return "Transform this sketch into fantasy illustration with magical elements, rich detail, and epic atmosphere."
        case .architecturalRender:
            return "Transform this sketch into a photorealistic architectural render with accurate materials, natural lighting, and environmental context."
        case .custom:
            return ""
        }
    }
}

enum AIServiceError: LocalizedError {
    case notConfigured(service: String)
    case invalidAPIKey(service: String)
    case rateLimited(retryAfter: TimeInterval)
    case contentFiltered(reason: String)
    case serverError(statusCode: Int, message: String)
    case networkError(underlying: Error)
    case invalidResponse
    case cancelled

    var errorDescription: String? {
        switch self {
        case .notConfigured(let service): return "\(service) API key not configured. Add it in Settings."
        case .invalidAPIKey(let service): return "\(service) API key is invalid (401 Unauthorized)."
        case .rateLimited: return "Rate limited. Please wait a moment and try again."
        case .contentFiltered(let reason): return "Content filtered: \(reason)"
        case .serverError(let code, let msg): return "Server error (\(code)): \(msg)"
        case .networkError(let err): return "Network error: \(err.localizedDescription)"
        case .invalidResponse: return "Invalid response from API"
        case .cancelled: return "Generation cancelled"
        }
    }
}
