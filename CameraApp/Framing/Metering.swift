import CoreGraphics
import Foundation

/// Histogram-based exposure metering over a specific crop.
///
/// Runs on the crop the framing engine chose, so the exposure it recommends
/// is for the *composition*, not for whatever happens to be at the edges.
enum Metering {
    struct Result {
        var meanLuminance: Double
        var medianLuminance: Double
        var clippedFraction: Double
        var shadowFraction: Double
        /// Stops to add (positive brightens) to hit the target.
        var evAdjustment: Double
        /// Set when the scene is too dark for a reliable reading.
        var isUnreliable: Bool
    }

    /// Target mean luminance. Chosen so a mid-grey subject lands comfortably
    /// inside the highlight headroom rather than against it.
    static let targetMean: Double = 0.42
    /// Keep at least this share of pixels off the clipping ceiling.
    static let maxClippedFraction: Double = 0.01

    static func measure(
        luminanceMap: [Float],
        width: Int,
        height: Int,
        crop: CGRect
    ) -> Result? {
        guard width > 0, height > 0, luminanceMap.count == width * height else { return nil }

        let x0 = clamp(Int(crop.minX * CGFloat(width)), 0, width - 1)
        let x1 = clamp(Int(crop.maxX * CGFloat(width)), x0 + 1, width)
        let y0 = clamp(Int(crop.minY * CGFloat(height)), 0, height - 1)
        let y1 = clamp(Int(crop.maxY * CGFloat(height)), y0 + 1, height)

        guard x1 > x0, y1 > y0 else { return nil }

        // 64-bin histogram over the crop.
        let bins = 64
        var histogram = [Int](repeating: 0, count: bins)
        var sum: Double = 0
        var count = 0
        var clipped = 0
        var shadows = 0

        for y in y0..<y1 {
            let row = y * width
            for x in x0..<x1 {
                let v = Double(luminanceMap[row + x])
                sum += v
                count += 1
                if v >= 0.985 { clipped += 1 }
                if v <= 0.04 { shadows += 1 }
                let bin = min(bins - 1, max(0, Int(v * Double(bins))))
                histogram[bin] += 1
            }
        }

        guard count > 0 else { return nil }

        let mean = sum / Double(count)
        let clippedFraction = Double(clipped) / Double(count)
        let shadowFraction = Double(shadows) / Double(count)

        // Median from the cumulative histogram.
        var cumulative = 0
        var median = 0.5
        let half = Double(count) / 2
        for (index, c) in histogram.enumerated() {
            cumulative += c
            if Double(cumulative) >= half {
                median = (Double(index) + 0.5) / Double(bins)
                break
            }
        }

        var ev = log2(max(mean, 1e-4) / max(targetMean, 1e-4))

        // Back off rather than blow out a frame that is already at the ceiling.
        if clippedFraction > maxClippedFraction {
            let penalty = (clippedFraction - maxClippedFraction) * 12.0
            ev -= penalty
        }
        // In a genuinely dark scene, pushing further just amplifies noise.
        if mean < 0.12 {
            ev *= 0.6
        }

        // Luminance is perceptual; the sensor is linear. Bridge the two with a
        // 1.6 gamma approximation, which is close enough for a suggestion.
        ev /= 1.6

        let unreliable = mean < 0.02

        return Result(
            meanLuminance: mean,
            medianLuminance: median,
            clippedFraction: clippedFraction,
            shadowFraction: shadowFraction,
            evAdjustment: clamp(ev, -2.5, 2.5),
            isUnreliable: unreliable
        )
    }
}