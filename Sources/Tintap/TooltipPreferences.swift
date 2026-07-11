import Foundation

struct TooltipPreferences: Sendable {
    var isSelectionEnabled: Bool
    var offsetX: Double
    var offsetY: Double
}

@MainActor
final class TooltipPreferencesStore {
    static let shared = TooltipPreferencesStore()

    private enum Keys {
        static let selectionEnabled = "tooltip.selectionEnabled"
        static let offsetX = "tooltip.offsetX"
        static let offsetY = "tooltip.offsetY"
    }

    private let defaults = UserDefaults.standard

    private init() {
        defaults.register(defaults: [
            Keys.selectionEnabled: true,
            Keys.offsetX: 0.0,
            Keys.offsetY: 0.0
        ])
    }

    func load() -> TooltipPreferences {
        TooltipPreferences(
            isSelectionEnabled: defaults.bool(forKey: Keys.selectionEnabled),
            offsetX: defaults.double(forKey: Keys.offsetX),
            offsetY: defaults.double(forKey: Keys.offsetY)
        )
    }

    func setSelectionEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Keys.selectionEnabled)
    }

    func saveOffsets(x: Double, y: Double) {
        defaults.set(x, forKey: Keys.offsetX)
        defaults.set(y, forKey: Keys.offsetY)
    }
}
