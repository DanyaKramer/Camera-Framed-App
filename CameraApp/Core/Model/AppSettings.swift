import Foundation
import SwiftUI

enum GridStyle: String, CaseIterable, Identifiable, Codable, Sendable {
    case off
    case thirds
    case golden
    case diagonals
    case center

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .off:       "Выкл"
        case .thirds:    "Трети"
        case .golden:    "Золотое сечение"
        case .diagonals: "Диагонали"
        case .center:    "Центр"
        }
    }

    var icon: String {
        switch self {
        case .off:       "square.slash"
        case .thirds:    "grid"
        case .golden:    "grid.circle"
        case .diagonals: "triangle"
        case .center:    "plus"
        }
    }
}

/// User-tweakable preferences.
///
/// A plain final class rather than an `@Observable` type on purpose: the values
/// live in `UserDefaults`, so they are read through and written straight through.
/// Wrapping them in observation would only add a layer that has to be kept in sync
/// with the store, and SwiftUI already re-renders because the owning controller
/// exposes the settings object itself.
final class AppSettings {
    private enum Key {
        static let gridStyle = "settings.gridStyle"
        static let gridOpacity = "settings.gridOpacity"
        static let aspect = "settings.aspect"
        static let depthOfFieldEnabled = "settings.dofEnabled"
        static let saveRAW = "settings.saveRAW"
        static let autoCapture = "settings.autoCapture"
        static let autoZoom = "settings.autoZoom"
        static let autoExposure = "settings.autoExposure"
        static let showHistogram = "settings.showHistogram"
        static let showLevel = "settings.showLevel"
        static let matchThreshold = "settings.matchThreshold"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var gridStyle: GridStyle {
        get { GridStyle(rawValue: defaults.string(forKey: Key.gridStyle) ?? "") ?? .thirds }
        set { defaults.set(newValue.rawValue, forKey: Key.gridStyle) }
    }

    var gridOpacity: Double {
        get { defaults.object(forKey: Key.gridOpacity) as? Double ?? 0.35 }
        set { defaults.set(newValue, forKey: Key.gridOpacity) }
    }

    var aspect: AspectRatio {
        get { AspectRatio(rawValue: defaults.string(forKey: Key.aspect) ?? "") ?? .landscape4x3 }
        set { defaults.set(newValue.rawValue, forKey: Key.aspect) }
    }

    var depthOfFieldEnabled: Bool {
        get { defaults.object(forKey: Key.depthOfFieldEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.depthOfFieldEnabled) }
    }

    var saveRAW: Bool {
        get { defaults.bool(forKey: Key.saveRAW) }
        set { defaults.set(newValue, forKey: Key.saveRAW) }
    }

    var autoCapture: Bool {
        get { defaults.bool(forKey: Key.autoCapture) }
        set { defaults.set(newValue, forKey: Key.autoCapture) }
    }

    var autoZoom: Bool {
        get { defaults.object(forKey: Key.autoZoom) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.autoZoom) }
    }

    var autoExposure: Bool {
        get { defaults.object(forKey: Key.autoExposure) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.autoExposure) }
    }

    var showHistogram: Bool {
        get { defaults.bool(forKey: Key.showHistogram) }
        set { defaults.set(newValue, forKey: Key.showHistogram) }
    }

    var showLevel: Bool {
        get { defaults.object(forKey: Key.showLevel) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Key.showLevel) }
    }

    /// 0…1 — how close the live frame must be to the target before "aligned".
    var matchThreshold: Double {
        get { defaults.object(forKey: Key.matchThreshold) as? Double ?? 0.85 }
        set { defaults.set(newValue, forKey: Key.matchThreshold) }
    }
}