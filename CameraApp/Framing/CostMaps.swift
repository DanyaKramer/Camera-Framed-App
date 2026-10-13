import CoreGraphics
import Foundation

/// The per-frame maps the crop search runs on.
///
/// Everything is pre-scaled to `width x height` (typically ~160 px on the long
/// edge) so the whole pipeline is cheap enough to run 10× per second.
struct CostMaps {
    let width: Int
    let height: Int

    /// Visual attention, 0…1.
    let saliency: IntegralImage
    /// Hard subject mask (faces / person / salient object), 0…1.
    let subject: IntegralImage
    /// Linear-ish luminance, 0…1.
    let luminance: IntegralImage
    /// Pixels at or near clipping, 0…1.
    let clipped: IntegralImage
    /// Edge density — used as a clutter proxy, 0…1.
    let edge: IntegralImage

    var aspect: CGFloat {
        guard height > 0 else { return 1 }
        return CGFloat(width) / CGFloat(height)
    }

    var bounds: CGRect { CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)) }

    /// Normalised rect → pixel rect.
    func pixels(_ normalized: CGRect) -> CGRect {
        CGRect(
            x: normalized.minX * CGFloat(width),
            y: normalized.minY * CGFloat(height),
            width: normalized.width * CGFloat(width),
            height: normalized.height * CGFloat(height)
        )
    }

    /// Sanity helper for empty frames.
    static func empty(width: Int = 16, height: Int = 16) -> CostMaps {
        let z = IntegralImage(values: [Float](repeating: 0, count: width * height), width: width, height: height)
        return CostMaps(
            width: width,
            height: height,
            saliency: z,
            subject: z,
            luminance: z,
            clipped: z,
            edge: z
        )
    }
}

/// Result of deciding *what* matters in the frame.
struct SubjectInfo: Equatable {
    enum Kind: Int, Comparable {
        case none = 0
        case object
        case person
        case face

        static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }

        var displayName: String {
            switch self {
            case .none: "нет явного объекта"
            case .object: "объект"
            case .person: "человек"
            case .face: "лицо"
            }
        }
    }

    var kind: Kind = .none
    /// Normalised bounding box of the primary subject.
    var bounds: CGRect?
    /// Normalised centroid.
    var centroid: CGPoint?
    /// Normalised y of the eye line (faces only).
    var eyeLineY: CGFloat?
    /// Unit-ish vector the subject faces, for leadroom.
    var facing: CGVector?
    var faceCount: Int = 0
    /// 0…1 detector confidence; multiplies the final score.
    var confidence: Double = 0

    var isEmpty: Bool { kind == .none || bounds == nil }

    static let none = SubjectInfo()
}