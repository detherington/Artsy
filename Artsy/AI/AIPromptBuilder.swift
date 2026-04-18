import Foundation

final class AIPromptBuilder {
    static func buildPrompt(
        userPrompt: String,
        style: AIStyle,
        preserveComposition: Bool = true,
        additionalInstructions: String? = nil
    ) -> String {
        var parts: [String] = []

        if style != .custom {
            parts.append(style.promptPrefix)
        }

        if !userPrompt.isEmpty {
            parts.append(userPrompt)
        }

        if preserveComposition {
            parts.append("Preserve the exact layout, proportions, and composition of the original sketch.")
        }

        parts.append("Do not add text, watermarks, or logos unless specifically requested.")

        if let additional = additionalInstructions {
            parts.append(additional)
        }

        return parts.joined(separator: " ")
    }
}
