import CoreGraphics
import Foundation

/// Summed-area table over a single-channel float map.
///
/// Built once per analysed frame, then every candidate crop costs four lookups.
/// This is what makes a few hundred candidate crops per frame essentially free.
struct IntegralImage {
    let width: Int
    let height: Int

    /// Dimensions are (width + 1) x (height + 1).
    private let table: [Double]
    /// Total sum of all values, for cheap global normalisation.
    let total: Double
    let pixelCount: Double

    init(values: [Float], width: Int, height: Int) {
        precondition(width > 0 && height > 0, "integral image needs a non-empty map")
        precondition(values.count == width * height, "values must be width*height")

        self.width = width
        self.height = height

        let stride = width + 1
        var t = [Double](repeating: 0, count: stride * (height + 1))

        for y in 0..<height {
            var rowSum: Double = 0
            let rowBase = y * width
            let prevBase = y * stride
            let curBase = (y + 1) * stride
            for x in 0..<width {
                rowSum += Double(values[rowBase + x])
                t[curBase + x + 1] = t[prevBase + x + 1] + rowSum
            }
        }

        self.table = t
        // The bottom-right corner of the summed-area table is the whole-map sum.
        self.total = t[(height) * stride + width]
        self.pixelCount = Double(width * height)
    }

    @inline(__always)
    private func at(_ x: Int, _ y: Int) -> Double {
        table[y * (width + 1) + x]
    }

    /// Sum over a pixel-space rect (the rect is clamped to the map).
    func sum(rect: CGRect) -> Double {
        let x0 = clamp(Int(rect.minX.rounded(.down)), 0, width)
        let y0 = clamp(Int(rect.minY.rounded(.down)), 0, height)
        let x1 = clamp(Int(rect.maxX.rounded(.up)), 0, width)
        let y1 = clamp(Int(rect.maxY.rounded(.up)), 0, height)
        guard x1 > x0, y1 > y0 else { return 0 }
        return at(x1, y1) - at(x0, y1) - at(x1, y0) + at(x0, y0)
    }

    /// Mean over a pixel-space rect; 0 for an empty rect.
    func average(rect: CGRect) -> Double {
        let w = clamp(rect.width, 0, CGFloat(width))
        let h = clamp(rect.height, 0, CGFloat(height))
        let area = Double(w * h)
        guard area > 0 else { return 0 }
        return sum(rect: rect) / area
    }

    /// Global mean over the whole map.
    var mean: Double { pixelCount > 0 ? total / pixelCount : 0 }
}

extension IntegralImage {
    /// Builds an integral image from a closure over normalised coordinates.
    static func build(
        width: Int,
        height: Int,
        value: (Int, Int) -> Double
    ) -> IntegralImage {
        var values = [Float](repeating: 0, count: width * height)
        for y in 0..<height {
            let rowBase = y * width
            for x in 0..<width {
                values[rowBase + x] = Float(value(x, y))
            }
        }
        return IntegralImage(values: values, width: width, height: height)
    }
}