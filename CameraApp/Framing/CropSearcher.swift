import CoreGraphics
import Foundation

/// Finds the best crop of a given aspect ratio from the cost maps.
///
/// Free parameters: centre (cx, cy) and height fraction `h`. The width follows
/// from the aspect constraint: `w = h * targetAspect / frameAspect`.
///
/// Strategy: coarse grid over scale, then coordinate descent over (cx, cy, h).
/// With integral images every candidate costs a handful of lookups, so this runs
/// comfortably inside the per-frame budget.
struct CropSearcher {
    struct Config {
        var centerSteps: Int = 9
        var scaleLevels: [CGFloat] = [1.0, 0.82, 0.68, 0.56, 0.46, 0.38, 0.31, 0.25]
        var refinementPasses: Int = 3
        /// Smallest allowed height fraction — bounded by the device's max zoom.
        var minHeightFraction: CGFloat = 0.12
        /// Never suggest a crop smaller than this fraction of the frame width.
        var minWidthFraction: CGFloat = 0.25
        var maxCandidatesScored: Int = 1200
    }

    let config: Config

    init(config: Config = Config()) {
        self.config = config
    }

    func search(
        maps: CostMaps,
        aspect: AspectRatio,
        subject: SubjectInfo,
        rollDegrees: Double,
        weights: CropScoreWeights = .default
    ) -> CropCandidate? {
        let frameAspect = maps.aspect
        let targetRatio = aspect.ratio

        let scorer = CropScorer(weights: weights)

        // Height bounds for this aspect and the device's zoom range.
        let maxHeight: CGFloat = 1.0
        var minHeight = max(config.minHeightFraction, config.minWidthFraction * frameAspect / targetRatio)
        // A crop wider than the frame is impossible, so cap the height accordingly.
        minHeight = max(minHeight, 0.02)
        if minHeight >= maxHeight {
            minHeight = maxHeight / 2
        }

        var best: CropCandidate?
        var scored = 0

        func rect(cx: CGFloat, cy: CGFloat, h: CGFloat) -> CGRect {
            let w = h * targetRatio / frameAspect
            return CGRect(
                x: clamp(cx - w / 2, 0, 1 - w),
                y: clamp(cy - h / 2, 0, 1 - h),
                width: w,
                height: h
            )
        }

        func evaluate(cx: CGFloat, cy: CGFloat, h: CGFloat) -> CropCandidate {
            let r = rect(cx: cx, cy: cy, h: h)
            let s = scorer.score(crop: r, maps: maps, subject: subject, rollDegrees: rollDegrees)
            let candidate = CropCandidate(rect: r, score: s)
            if best == nil || candidate > best! {
                best = candidate
            }
            scored += 1
            return candidate
        }

        // Phase 1: coarse grid.
        for h in config.scaleLevels where h >= minHeight && h <= maxHeight {
            let w = h * targetRatio / frameAspect
            guard w <= 1 else { continue }
            for iy in 0..<config.centerSteps {
                let fy = CGFloat(iy) / CGFloat(config.centerSteps - 1)
                let cy = h / 2 + fy * (1 - h)
                for ix in 0..<config.centerSteps {
                    let fx = CGFloat(ix) / CGFloat(config.centerSteps - 1)
                    let cx = w / 2 + fx * (1 - w)
                    evaluate(cx: cx, cy: cy, h: h)
                }
            }
            if scored > config.maxCandidatesScored { break }
        }

        // Phase 2: coordinate descent around the leader.
        if var current = best {
            var stepCenter: CGFloat = 0.14
            var stepScale: CGFloat = 0.12

            for _ in 0..<config.refinementPasses {
                var improved = false
                let w = current.rect.width
                let h = current.rect.height
                let cx = current.rect.midX
                let cy = current.rect.midY

                let centreCandidates: [(CGFloat, CGFloat)] = [
                    (cx - stepCenter, cy), (cx + stepCenter, cy),
                    (cx, cy - stepCenter), (cx, cy + stepCenter),
                    (cx - stepCenter, cy - stepCenter),
                    (cx + stepCenter, cy + stepCenter),
                    (cx - stepCenter, cy + stepCenter),
                    (cx + stepCenter, cy - stepCenter)
                ]
                for (nx, ny) in centreCandidates {
                    let c = evaluate(cx: nx, cy: ny, h: h)
                    if c > current { current = c; improved = true }
                }

                for scaleStep in [-stepScale, stepScale] {
                    let nh = clamp(h * (1 + scaleStep), minHeight, maxHeight)
                    guard nh != h else { continue }
                    let c = evaluate(cx: cx, cy: cy, h: nh)
                    if c > current { current = c; improved = true }
                }

                if !improved {
                    stepCenter *= 0.5
                    stepScale *= 0.5
                }
            }
        }

        return best
    }

    /// Given a target crop and the current zoom, the zoom that makes the crop
    /// fill the frame. Relative to the frame *as currently visible*.
    ///
    /// Derivation: at zoom `z` the visible width is `W/z`. The crop is a fraction
    /// `f` of that. To make the crop fill the frame we need `W/z' = f · W/z`,
    /// hence `z' = z / f`.
    static func zoom(forCrop crop: CGRect, currentZoom: CGFloat) -> CGFloat {
        let f = max(crop.width, 1e-3)
        return currentZoom / f
    }

    /// Inverse: which crop is visible right now, at a given zoom?
    static func visibleCrop(currentZoom: CGFloat, frameAspect: CGFloat, aspect: AspectRatio) -> CGRect {
        let h = 1.0 / max(currentZoom, 1e-3)
        let w = h * aspect.ratio / frameAspect
        return CGRect(x: (1 - w) / 2, y: (1 - h) / 2, width: w, height: h)
    }
}