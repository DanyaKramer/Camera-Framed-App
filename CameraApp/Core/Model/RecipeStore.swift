import Foundation

/// Simple file-backed persistence for saved framing recipes.
final class RecipeStore {
    static let shared = RecipeStore()

    private let url: URL
    private let queue = DispatchQueue(label: "com.frameapp.recipes")

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("Frame", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        url = dir.appendingPathComponent("recipes.json")
    }

    func load() -> [FramingRecipe] {
        queue.sync {
            guard let data = try? Data(contentsOf: url) else { return [] }
            let decoder = JSONDecoder()
            return (try? decoder.decode([FramingRecipe].self, from: data)) ?? []
        }
    }

    func save(_ recipes: [FramingRecipe]) {
        queue.async { [url] in
            let encoder = JSONEncoder()
            guard let data = try? encoder.encode(recipes) else { return }
            try? data.write(to: url, options: .atomic)
        }
    }
}