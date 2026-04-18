import Foundation
import AppKit

final class AIResultsManager: ObservableObject {
    @Published var results: [AIGeneratedImage] = []
    @Published var isGenerating = false
    @Published var error: String?
    @Published var progress: String?

    let openAIService = OpenAIService()
    let geminiService = GeminiService()
    let configuration = AIConfiguration()

    var activeService: AIImageService {
        switch configuration.preferredService {
        case .openAI: return openAIService
        case .google: return geminiService
        }
    }

    func transformSketch(imageData: Data, prompt: String, style: AIStyle?, quality: AIQuality) async {
        await MainActor.run {
            isGenerating = true
            error = nil
            progress = "Generating with \(activeService.name)..."
        }

        do {
            let images = try await activeService.transform(
                sketch: imageData,
                prompt: prompt,
                style: style,
                quality: quality
            )
            await MainActor.run {
                results.insert(contentsOf: images, at: 0)
                isGenerating = false
                progress = nil
            }
        } catch {
            await MainActor.run {
                self.error = error.localizedDescription
                isGenerating = false
                progress = nil
            }
        }
    }

    func generateFromPrompt(prompt: String, style: AIStyle?, quality: AIQuality, size: AIImageSize) async {
        await MainActor.run {
            isGenerating = true
            error = nil
            progress = "Generating with \(activeService.name)..."
        }

        do {
            let images = try await activeService.generate(
                prompt: prompt,
                style: style,
                quality: quality,
                size: size
            )
            await MainActor.run {
                results.insert(contentsOf: images, at: 0)
                isGenerating = false
                progress = nil
            }
        } catch {
            await MainActor.run {
                self.error = error.localizedDescription
                isGenerating = false
                progress = nil
            }
        }
    }

    func cancel() {
        activeService.cancel()
        isGenerating = false
        progress = nil
    }

    func imageToNSImage(_ generatedImage: AIGeneratedImage) -> NSImage? {
        NSImage(data: generatedImage.imageData)
    }
}
