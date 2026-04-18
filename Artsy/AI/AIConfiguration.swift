import Foundation

final class AIConfiguration: ObservableObject {
    @Published var preferredService: AIServiceType = .openAI
    @Published var openAIModel: OpenAIModel = .gptImage15
    @Published var googleModel: GoogleModel = .flashImage
    @Published var defaultQuality: AIQuality = .medium
    @Published var defaultStyle: AIStyle = .photorealistic
    @Published var preserveComposition: Bool = true
    @Published var numberOfVariants: Int = 2

    enum AIServiceType: String, CaseIterable, Identifiable {
        case openAI = "OpenAI"
        case google = "Google"

        var id: String { rawValue }
    }

    enum OpenAIModel: String, CaseIterable, Identifiable {
        case gptImage15 = "gpt-image-1.5"
        case gptImage1Mini = "gpt-image-1-mini"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .gptImage15: return "GPT Image 1.5"
            case .gptImage1Mini: return "GPT Image 1 Mini"
            }
        }
    }

    enum GoogleModel: String, CaseIterable, Identifiable {
        case flashImage = "gemini-2.5-flash-image"
        case flashImagePreview = "gemini-3.1-flash-image-preview"
        case proImagePreview = "gemini-3-pro-image-preview"

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .flashImage: return "Gemini 2.5 Flash Image"
            case .flashImagePreview: return "Gemini 3.1 Flash Image"
            case .proImagePreview: return "Gemini 3 Pro Image"
            }
        }
    }
}
