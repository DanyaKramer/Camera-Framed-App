import CoreGraphics
import Foundation

/// Tunable weights for the composition scorer.
///
/// Kept in one place on purpose: framing taste is a product decision, not a
/// technical one, and these should be adjustable without touching the search.
struct CropScoreWeights: Sendable {
    var subjectProminence: Double = 0.9
    var subjectFill: Double = 0.8
    var thirds: Double = 1.3
    var headroom: Double = 0.7
    var leadroom: Double = 0.35
    var breathingRoom: Double = 0.8
    var horizon: Double = 0.9
    var exposure: Double = 0.7
    var clutter: Double = 0.45
    /// Small penalty for dead-centre placement — it reads as lazy framing.
    var centerBias: Double = 0.25

    /// How much of the frame the subject should fill, per subject kind.
    var targetFill: Double = 0.45
    var fillTolerance: Double = 0.28

    static let `default` = CropScoreWeights()
}

struct CropScore: Equatable {
    var total: Double
    var components: [String: Double]
}

struct CropCandidate: Equatable {
    var rect: CGRect
    var score: CropScore

    /// Zoom factor that makes `rect` fill the frame, relative to the frame at zoom 1.
    var requiredZoom: CGFloat { 1.0 / max(rect.width, 0.001) }
}

extension CropScore {
    static func > (a: CropScore, b: CropScore) -> Bool { a.total > b.total }
}

extension CropCandidate {
    static func > (a: CropCandidate, b: CropCandidate) -> Bool { a.score.total > b.score.total }
}

/// Scores a candidate crop for photographic quality.
///
/// Every term is a 0…1 "bump" function, so the total is directly comparable across
/// candidates and easy to inspect in the debug overlay.
struct CropScorer {
    let weights: CropScoreWeights

    init(weights: CropScoreWeights = .default) {
        self.weights = weights
    }

    func score(
        crop: CGRect,
        maps: CostMaps,
        subject: SubjectInfo,
        rollDegrees: Double
    ) -> CropScore {
        var parts: [String: Double] = [:]
        let pixels = maps.pixels(crop)

        // The subject's own centroid, if it is inside this crop; otherwise the
        // crop centre acts as the stand-in "point of interest".
        let subjectCentroidInside: CGPoint? = subject.centroid.flatMap {
            crop.contains($0) ? $0 : nil
        }
        let pointOfInterest = subjectCentroidInside ?? crop.center

        // 1. Prominence — is the interesting stuff brighter than the rest of the frame?
        let saliencyInside = maps.saliency.average(rect: pixels)
        let saliencyGlobal = maps.saliency.mean
        let prominence = saliencyGlobal > 1e-5
            ? clamp(saliencyInside / saliencyGlobal, 0, 3) / 1.4
            : 0
        parts["subject"] = clamp(prominence, 0, 1)

        // 2. Fill — how much of the crop the subject occupies. Too small loses impact,
//    too large crowds the edges.
        let capturedMass = maps.subject.sum(rect: pixels)
        let pixelCropArea = max(Double(pixels.width * pixels.height), 1.0)
        let normalizedFill = maps.subject.total > 0.5 ? capturedMass / pixelCropArea : 0
        parts["fill"] = normalizedFill > 0
            ? bump(normalizedFill, center: weights.targetFill, width: weights.fillTolerance)
            : 0.35

        // 3. Rule of thirds — distance to the nearest power point.
        let thirdsScore = powerPointScore(point: pointOfInterest, in: crop)
        // Dead-centre framing loses a little.
        let centerProximity = bump(
            Double(pointOfInterest.x - crop.midX),
            center: 0, width: Double(crop.width) * 0.12
        ) * bump(Double(pointOfInterest.y - crop.midY), center: 0, width: Double(crop.height) * 0.12)
        parts["thirds"] = clamp(thirdsScore - weights.centerBias * centerProximity * 0.4, 0, 1)

        // 4. Headroom — eyes belong on or above the upper third.
        if let eyeY = subject.eyeLineY, crop.contains(CGPoint(x: subject.centroid?.x ?? crop.midX, y: eyeY)) {
            let relative = Double((eyeY - crop.minY) / crop.height)
            parts["headroom"] = bump(relative, center: 0.34, width: 0.20)
        } else {
            parts["headroom"] = 0.5 // neutral, not penalised
        }

        // 5. Leadroom — breathing room on the side the subject faces.
        if let facing = subject.facing, subjectCentroidInside != nil {
            let dx = Double(facing.dx)
            parts["leadroom"] = clamp(0.5 + 0.5 * (dx * -1) * Double((crop.midX - (subject.centroid?.x ?? crop.midX)) / crop.width), 0, 1)
        } else {
            parts["leadroom"] = 0.5
        }

        // 6. Breathing room — the subject should not touch the crop edge.
        if let bounds = subject.bounds {
            let inner = crop.insetByFraction(0.03, 0.03)
            let overlap = bounds.intersectionArea(inner) / max(bounds.area, 1e-6)
            parts["breathing"] = smoothstep(0.72, 0.97, Double(overlap))
        } else {
            parts["breathing"] = 0.6
        }

        // 7. Horizon — reward a level camera.
        parts["horizon"] = bump(Double(rollDegrees), center: 0, width: 2.4)

        // 8. Exposure — penalise clipped highlights and a muddy overall level.
        let clippedFraction = maps.clipped.average(rect: pixels)
        let meanLuma = maps.luminance.average(rect: pixels)
        var exposure = bump(clippedFraction, center: 0, width: 0.02)
        exposure *= bump(meanLuma, center: 0.42, width: 0.22)
        parts["exposure"] = clamp(exposure, 0, 1)

        // 9. Clutter — edge density in a border band around the crop.
        let inner = crop.insetByFraction(0.12, 0.12)
        let bandArea = max(crop.area - inner.area, 1e-6)
        let bandEdges = maps.edge.sum(rect: pixels) - maps.edge.sum(rect: maps.pixels(inner))
        let bandDensity = Double(bandEdges / bandArea)
        parts["clutter"] = bump(bandDensity, center: 0, width: 0.20)

        // Combine.
        let pairs: [(Double, Double)] = [
            (weights.subjectProminence, parts["subject"] ?? 0),
            (weights.subjectFill, parts["fill"] ?? 0),
            (weights.thirds, parts["thirds"] ?? 0),
            (weights.headroom, parts["headroom"] ?? 0),
            (weights.leadroom, parts["leadroom"] ?? 0),
            (weights.breathingRoom, parts["breathing"] ?? 0),
            (weights.horizon, parts["horizon"] ?? 0),
            (weights.exposure, parts["exposure"] ?? 0),
            (weights.clutter, parts["clutter"] ?? 0)
        ]
        let weightSum = pairs.reduce(0) { $0 + $1.0 }
        let weighted = pairs.reduce(0) { $0 + $1.0 * $1.1 }
        var total = weightSum > 0 ? weighted / weightSum : 0

        // Without any detected subject the composition terms are weak evidence,
        // so shrink towards the middle instead of over-committing.
        let confidence = subject.isEmpty ? 0.65 : subject.confidence
        total = 0.5 + (total - 0.5) * confidence

        return CropScore(total: clamp(total, 0, 1), components: parts)
    }

    /// 1 when the point sits on a power point, decaying with distance.
    private func powerPointScore(point: CGPoint, in crop: CGRect) -> Double {
        let targets: [(CGFloat, CGFloat)] = [(1.0 / 3.0, 1.0 / 3.0), (2.0 / 3.0, 1.0 / 3.0),
                                             (1.0 / 3.0, 2.0 / 3.0), (2.0 / 3.0, 2.0 / 3.0)]
        var best = Double.greatestFiniteMagnitude
        for (tx, ty) in targets {
            let px = crop.minX + tx * crop.width
            let py = crop.minY + ty * crop.height
            let dx = (point.x - px) / max(crop.width, 1e-6)
            let dy = (point.y - py) / max(crop.height, 1e-6)
            let d = sqrt(Double(dx * dx + dy * dy))
            best = min(best, d)
        }
        return clamp(1.0 - best / 0.30, 0, 1)
    }
}