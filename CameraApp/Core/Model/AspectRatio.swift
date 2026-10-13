import SwiftUI

/// Capture aspect ratios.
///
/// `ratio` is width/height **of the crop expressed in sensor-frame coordinates**.
/// The sensor frame is always landscape, so portrait options (3:4, 9:16) have a
/// ratio below 1 — that is, a crop that is taller than it is wide. Rotating that
/// crop 90° for storage/exif yields the familiar portrait photo.
enum AspectRatio: String, CaseIterable, Identifiable, Codable, Sendable {
    case square         = "1:1"
    case portrait3x4    = "3:4"
    case landscape4x3   = "4:3"
    case landscape16x9  = "16:9"
    case portrait9x16   = "9:16"

    var id: String { rawValue }

    /// width / height in frame coordinates.
    var ratio: CGFloat {
        switch self {
        case .square:        1
        case .portrait3x4:   3.0 / 4.0
        case .landscape4x3:  4.0 / 3.0
        case .landscape16x9: 16.0 / 9.0
        case .portrait9x16:  9.0 / 16.0
        }
    }

    var isPortrait: Bool { ratio < 1 }
    var isLandscape: Bool { ratio > 1 }

    var displayName: String { rawValue }

    var icon: String {
        switch self {
        case .square:         "square"
        case .portrait3x4:    "rectangle.portrait"
        case .landscape4x3:   "rectangle"
        case .landscape16x9:  "rectangle.inset.filled"
        case .portrait9x16:   "iphone"
        }
    }

    var next: AspectRatio {
        let all = AspectRatio.allCases
        let i = all.firstIndex(of: self) ?? 0
        return all[(i + 1) % all.count]
    }

    /// The inverse ratio — the same rectangle after a 90° turn.
    var rotated: AspectRatio {
        switch self {
        case .square:        .square
        case .portrait3x4:   .landscape4x3
        case .landscape4x3:  .portrait3x4
        case .landscape16x9: .portrait9x16
        case .portrait9x16:  .landscape16x9
        }
    }
}