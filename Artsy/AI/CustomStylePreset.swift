import Foundation

struct CustomStylePreset: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var prompt: String
    var createdAt: Date

    init(id: UUID = UUID(), name: String, prompt: String) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.createdAt = Date()
    }
}

final class CustomStyleStore: ObservableObject {
    @Published var presets: [CustomStylePreset] = []

    private static let storageKey = "com.artsy.custom-style-presets"

    init() {
        load()
    }

    func add(name: String, prompt: String) {
        let preset = CustomStylePreset(name: name, prompt: prompt)
        presets.append(preset)
        save()
    }

    func update(_ preset: CustomStylePreset) {
        if let index = presets.firstIndex(where: { $0.id == preset.id }) {
            presets[index] = preset
            save()
        }
    }

    func delete(_ preset: CustomStylePreset) {
        presets.removeAll { $0.id == preset.id }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(presets) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let loaded = try? JSONDecoder().decode([CustomStylePreset].self, from: data) else {
            return
        }
        presets = loaded
    }
}
