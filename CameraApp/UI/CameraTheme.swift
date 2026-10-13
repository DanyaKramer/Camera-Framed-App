import SwiftUI

/// Colour language of the camera UI.
///
/// Only three states carry meaning, and colour is what makes them readable at a
/// glance without reading a word:
///   - `accent`  — the app's own voice: "I suggest something".
///   - `live`    — "you still need to move"; amber, urgent but not alarming.
///   - `success` — "this is the shot"; green, matched, go.
enum CameraTheme {
    /// Primary brand colour for the scan affordance and zoom pills.
    static let accent = Color(red: 1.00, green: 0.82, blue: 0.20)

    /// "Adjust the camera."
    static let live = Color(red: 1.00, green: 0.72, blue: 0.10)

    /// "Framing is correct."
    static let success = Color(red: 0.18, green: 0.85, blue: 0.45)

    static let chromeFill = Color.black.opacity(0.45)
    static let chromeStroke = Color.white.opacity(0.22)

    /// Colour for a given guidance phase.
    static func tint(for phase: GuidancePhase) -> Color {
        switch phase {
        case .idle: .white
        case .guiding: live
        case .aligned: success
        }
    }
}

/// Where the camera currently is relative to the suggested framing.
enum GuidancePhase {
    case idle
    case guiding
    case aligned

    var isActive: Bool { self != .idle }
}