import CoreGraphics
import Foundation

@inline(__always)
func clamp<T: Comparable>(_ value: T, _ lower: T, _ upper: T) -> T {
    min(max(value, lower), upper)
}

@inline(__always)
func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat {
    a + (b - a) * t
}

/// Smooth 0→1 ramp. `edge0` <= `edge1`.
@inline(__always)
func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
    guard edge1 > edge0 else { return x < edge0 ? 0 : 1 }
    let t = clamp((x - edge0) / (edge1 - edge0), 0, 1)
    return t * t * (3 - 2 * t)
}

/// Gaussian-ish bump peaking at 1.0 when `x == center`, falling to ~0 at `|x-center| >= width`.
@inline(__always)
func bump(_ x: Double, center: Double, width: Double) -> Double {
    guard width > 0 else { return 0 }
    let d = (x - center) / width
    return exp(-d * d)
}

extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat {
        hypot(x - other.x, y - other.y)
    }
}

extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
    var area: CGFloat { width * height }

    func insetByFraction(_ fx: CGFloat, _ fy: CGFloat) -> CGRect {
        CGRect(
            x: minX + width * fx,
            y: minY + height * fy,
            width: max(0, width * (1 - 2 * fx)),
            height: max(0, height * (1 - 2 * fy))
        )
    }

    func clampedToBounds(_ bounds: CGRect) -> CGRect {
        let x0 = max(minX, bounds.minX)
        let y0 = max(minY, bounds.minY)
        let x1 = min(maxX, bounds.maxX)
        let y1 = min(maxY, bounds.maxY)
        guard x1 > x0, y1 > y0 else { return .zero }
        return CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
    }

    func intersectionArea(_ other: CGRect) -> CGFloat {
        let r = intersection(other)
        guard !r.isNull, !r.isEmpty else { return 0 }
        return r.width * r.height
    }

    func iou(_ other: CGRect) -> Double {
        let inter = intersectionArea(other)
        guard inter > 0 else { return 0 }
        return Double(inter / (area + other.area - inter))
    }

    /// Converts a normalised rect into pixel coordinates of a `pixelWidth × pixelHeight` map.
    func denormalized(pixelWidth: Int, pixelHeight: Int) -> CGRect {
        CGRect(
            x: minX * CGFloat(pixelWidth),
            y: minY * CGFloat(pixelHeight),
            width: width * CGFloat(pixelWidth),
            height: height * CGFloat(pixelHeight)
        )
    }

    /// Converts a pixel-space rect back into normalised coordinates.
    func normalized(pixelWidth: Int, pixelHeight: Int) -> CGRect {
        guard pixelWidth > 0, pixelHeight > 0 else { return .zero }
        return CGRect(
            x: minX / CGFloat(pixelWidth),
            y: minY / CGFloat(pixelHeight),
            width: width / CGFloat(pixelWidth),
            height: height / CGFloat(pixelHeight)
        )
    }

    /// The largest rect with `aspect` (w/h) that fits inside `bounds`, centred.
    static func largestWithAspect(_ aspect: CGFloat, in bounds: CGRect) -> CGRect {
        guard bounds.width > 0, bounds.height > 0, aspect > 0 else { return .zero }
        var w = bounds.width
        var h = w / aspect
        if h > bounds.height {
            h = bounds.height
            w = h * aspect
        }
        return CGRect(
            x: bounds.midX - w / 2,
            y: bounds.midY - h / 2,
            width: w,
            height: h
        )
    }
}

extension CMTime {
    /// Seconds as a Double; safe for the invalid time.
    var seconds: Double {
        if !isValid { return 0 }
        let v = CMTimeGetSeconds(self)
        return v.isFinite ? v : 0
    }
}