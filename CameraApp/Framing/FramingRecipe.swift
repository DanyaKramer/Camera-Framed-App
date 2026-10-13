import CoreGraphics
import Foundation
import UIKit

/// The result of one scan: everything needed to reproduce a framing exactly.
///
/// ## Why zoom *and* a post-crop
/// `AVCaptureDevice.videoZoomFactor` always produces a **centred** crop. A crop
/// chosen off-centre for composition reasons therefore cannot be reproduced by
/// zoom alone. The solver below spends the full zoom budget and then carries the
/// residual offset as a normalised crop applied to the delivered full-resolution
/// photo — which is what keeps the preview WYSIWYG.
struct FramingRecipe: Identifiable, Codable, Equatable {
    var id = UUID()

    /// Absolute zoom factor to set on the device.
    var zoom: CGFloat

    /// Normalised crop applied to the delivered photo, 0…1, top-left origin.
    var photoCrop: CGRect

    var aspect: AspectRatio

    /// Stops to add on top of the metered auto exposure.
    var evAdjustment: Double
    /// Camera roll in degrees, positive = tilted clockwise.
    var rollDegrees: Double

    var confidence: Double
    var subjectKind: String
    var subjectBounds: CGRect?
    var meanLuminance: Double
    var clippedFraction: Double

    /// Small preview of the proposed framing, for the review screen.
    var thumbnail: Data?

    var evLabel: String {
        abs(evAdjustment) < 0.05 ? "±0 EV" : String(format: "%+.1f EV", evAdjustment)
    }

    var zoomLabel: String { String(format: "%.1f×", zoom) }
    var rollLabel: String { String(format: "%+.1f°", rollDegrees) }

    /// Convenience for rendering a thumbnail from stored bytes.
    var thumbnailImage: UIImage? {
        guard let thumbnail else { return nil }
        return UIImage(data: thumbnail)
    }
}

/// Turns a crop expressed in the *currently visible* area into an actionable
/// (zoom, post-crop) pair.
enum FramingSolver {
    /// The region visible at zoom 1, normalised in zoom-1 frame coordinates.
    static func visibleRegion(zoom: CGFloat) -> CGRect {
        let s = 1.0 / max(zoom, 0.001)
        return CGRect(x: (1 - s) / 2, y: (1 - s) / 2, width: s, height: s)
    }

    /// Re-expresses a crop found in the current visible area in zoom-1 coordinates.
    static func toZoomOneFrame(crop: CGRect, currentZoom: CGFloat) -> CGRect {
        let visible = visibleRegion(zoom: currentZoom)
        return CGRect(
            x: visible.minX + crop.minX * visible.width,
            y: visible.minY + crop.minY * visible.height,
            width: crop.width * visible.width,
            height: crop.height * visible.height
        )
    }

    struct Solution {
        var zoom: CGFloat
        /// Normalised within the photo the camera will actually deliver.
        var photoCrop: CGRect
        /// The same region in zoom-1 frame coordinates, for debug overlays.
        var regionInZoomOneFrame: CGRect
        /// True when the device's zoom ceiling forced a wider framing than asked.
        var wasLimited: Bool
    }

    /// Solves for zoom + post-crop.
    ///
    /// 1. The zoom that makes the crop exactly fill the frame:
    ///    `z' = z / cropWidth`  (crop sizes are already zoom-1 units at this point).
    /// 2. Zoom alone cannot pan, so the crop must fit *inside* the centred visible
    ///    region with room for the offset:
    ///    `z ≤ 1 / (cropSize + 2·offset)`.
    /// 3. Take the smaller, then project the crop into the delivered photo.
    static func solve(
        cropInZoomOneFrame crop: CGRect,
        currentZoom: CGFloat,
        limits: ClosedRange<CGFloat>
    ) -> Solution {
        let cropSize = CGSize(width: crop.width, height: crop.height)
        let offset = CGVector(dx: crop.midX - 0.5, dy: crop.midY - 0.5)

        // Step 1: the "fills the frame" zoom.
        let zoomToFill = currentZoom / max(cropSize.width, 1e-4)

        // Step 2: the largest zoom that still contains the offset crop.
        let neededWidth = cropSize.width + 2 * abs(offset.dx)
        let neededHeight = cropSize.height + 2 * abs(offset.dy)
        let zoomForContainment = 1.0 / max(neededWidth, neededHeight, 1e-4)

        let ideal = min(zoomToFill, zoomForContainment)
        let zoom = clamp(ideal, max(limits.lowerBound, 0.01), limits.upperBound)
        let wasLimited = zoom < ideal - 0.001

        // Step 3: project the requested crop into the frame the camera will deliver.
        let visible = visibleRegion(zoom: zoom)
        let intersection = crop.intersection(visible)
        let finalRegion = intersection.isNull || intersection.isEmpty ? visible : intersection

        let photoCrop = CGRect(
            x: (finalRegion.minX - visible.minX) / visible.width,
            y: (finalRegion.minY - visible.minY) / visible.height,
            width: finalRegion.width / visible.width,
            height: finalRegion.height / visible.height
        ).clampedToBounds(CGRect(x: 0, y: 0, width: 1, height: 1))

        return Solution(
            zoom: zoom,
            photoCrop: photoCrop.isEmpty ? CGRect(x: 0, y: 0, width: 1, height: 1) : photoCrop,
            regionInZoomOneFrame: finalRegion,
            wasLimited: wasLimited
        )
    }
}

/// Everything one analysis pass produced, regardless of whether it became a recipe.
/// Live matching reuses this to compare the current frame with a target recipe.
struct FramingAnalysis {
    /// Best crop, normalised in the analysed (currently visible) area.
    var crop: CGRect
    var aspect: AspectRatio
    var score: Double
    var scoreComponents: [String: Double]
    var subject: SubjectInfo
    var rollDegrees: Double
    var meanLuminance: Double
    var clippedFraction: Double
    var evAdjustment: Double
    var subjectBounds: CGRect?

    static func fallback(
        aspect: AspectRatio,
        frameAspect: CGFloat,
        zoom: CGFloat
    ) -> FramingAnalysis {
        FramingAnalysis(
            crop: CropSearcher.visibleCrop(currentZoom: zoom, frameAspect: frameAspect, aspect: aspect),
            aspect: aspect,
            score: 0,
            scoreComponents: [:],
            subject: .none,
            rollDegrees: 0,
            meanLuminance: 0.5,
            clippedFraction: 0,
            evAdjustment: 0,
            subjectBounds: nil
        )
    }
}

/// How well the live frame matches a target recipe, and what to do about it.
struct MatchResult: Equatable {
    /// Where the subject is versus where it should be, as a fraction of the frame.
    /// Positive x means "move the camera to the right".
    var panVector: CGVector = .zero
    /// Zoom correction in stops. Positive means zoom in.
    var zoomStops: Double = 0
    /// Stops to add.
    var evDelta: Double = 0
    /// Degrees to correct roll.
    var rollDelta: Double = 0
    /// 0…1 overall closeness.
    var match: Double = 0
    var isAligned: Bool = false

    /// Every axis that is out of tolerance.
    var hints: [String] = []
    /// The single most urgent correction.
    ///
    /// Showing one action at a time is deliberate: a row of simultaneous
    /// instructions is unactionable, and the user cannot know which one matters.
    var primaryInstruction: String = "Кадр совпадает"

    static let idle = MatchResult()
}

/// Compares the live frame's own best framing with the stored recipe.
struct LiveMatcher {
    struct Config {
        /// Position tolerance, as a fraction of the frame, before a pan hint appears.
        var panTolerance: Double = 0.015
        /// Zoom tolerance in stops before a zoom hint appears.
        var zoomTolerance: Double = 0.05
        /// Exposure tolerance in stops before an exposure hint appears.
        var evTolerance: Double = 0.15
        /// Roll tolerance in degrees.
        var rollTolerance: Double = 0.8
        /// Consecutive in-tolerance frames required before "aligned".
        var alignedStreakRequired: Int = 3
    }

    let config: Config

    init(config: Config = Config()) {
        self.config = config
    }

    func match(live: FramingAnalysis, target: FramingRecipe, threshold: Double) -> MatchResult {
        var result = MatchResult()

        // The preview at the target zoom shows exactly what the photo will show,
        // so `target.photoCrop` and `live.crop` live in the same space.
        let targetCrop = target.photoCrop
        let liveCrop = live.crop

        // --- Position -------------------------------------------------------
        let livePoint = live.subject.centroid ?? liveCrop.center
        let targetPoint = target.subjectBounds.map { targetCrop.center } ?? targetCrop.center
        let dx = Double(targetPoint.x - livePoint.x)
        let dy = Double(targetPoint.y - livePoint.y)
        let normalizedDx = dx / max(liveCrop.width, 1e-3)
        let normalizedDy = dy / max(liveCrop.height, 1e-3)

        result.panVector = CGVector(
            dx: CGFloat(normalizedDx),
            dy: CGFloat(normalizedDy)
        )

        // --- Zoom -----------------------------------------------------------
        // Target zoom expressed as a crop width inside the live frame, so that
        // "current zoom × 2^stops" lands on the requested framing.
        let liveWidth = max(liveCrop.width, 1e-3)
        let targetWidth = max(targetCrop.width, 1e-3)
        result.zoomStops = log2(Double(targetWidth / liveWidth))

        // --- Exposure / roll -------------------------------------------------
        result.evDelta = target.evAdjustment - live.evAdjustment
        result.rollDelta = target.rollDegrees - live.rollDegrees

        // --- Composite ------------------------------------------------------
        let positionTerm = 1 - min(1, hypot(normalizedDx, normalizedDy) / 0.06)
        let zoomTerm = 1 - min(1, abs(result.zoomStops) / 0.20)
        let exposureTerm = 1 - min(1, abs(result.evDelta) / 0.5)
        let rollTerm = 1 - min(1, abs(result.rollDelta) / 3.0)
        let subjectTerm: Double = {
            guard let a = live.subjectBounds, let b = target.subjectBounds else { return 0.7 }
            return a.iou(b)
        }()

        let raw = 0.40 * positionTerm + 0.25 * zoomTerm + 0.15 * exposureTerm
            + 0.10 * rollTerm + 0.10 * subjectTerm

        result.match = clamp(raw / 0.92, 0, 1)
        result.isAligned = result.match >= threshold

        var hints: [String] = []
        if abs(normalizedDx) > config.panTolerance {
            hints.append(normalizedDx > 0 ? "Сместите вправо" : "Сместите влево")
        }
        if abs(normalizedDy) > config.panTolerance {
            hints.append(normalizedDy > 0 ? "Сместите вниз" : "Сместите вверх")
        }
        if abs(result.zoomStops) > config.zoomTolerance {
            hints.append(result.zoomStops > 0 ? "Приблизьте" : "Отдалите")
        }
        if abs(result.rollDelta) > config.rollTolerance {
            hints.append(result.rollDelta > 0 ? "Наклоните влево" : "Наклоните вправо")
        }
        if abs(result.evDelta) > config.evTolerance {
            hints.append(result.evDelta > 0 ? "Добавить света" : "Убавить света")
        }
        result.hints = hints

        // Pick the single worst axis, measured in units of its own tolerance.
        struct Candidate {
            let urgency: Double
            let instruction: String
        }
        var candidates: [Candidate] = []

        let panUrgency = hypot(normalizedDx, normalizedDy) / max(config.panTolerance, 1e-4)
        if panUrgency > 1 {
            candidates.append(Candidate(urgency: panUrgency, instruction: panInstruction(dx: normalizedDx, dy: normalizedDy)))
        }
        let zoomUrgency = abs(result.zoomStops) / max(config.zoomTolerance, 1e-4)
        if zoomUrgency > 1 {
            candidates.append(Candidate(
                urgency: zoomUrgency,
                instruction: result.zoomStops > 0 ? "Приблизьте" : "Отдалите"
            ))
        }
        let rollUrgency = abs(result.rollDelta) / max(config.rollTolerance, 1e-4)
        if rollUrgency > 1 {
            candidates.append(Candidate(
                urgency: rollUrgency,
                instruction: result.rollDelta > 0 ? "Наклоните телефон влево" : "Наклоните телефон вправо"
            ))
        }
        let exposureUrgency = abs(result.evDelta) / max(config.evTolerance, 1e-4)
        if exposureUrgency > 1 {
            candidates.append(Candidate(
                urgency: exposureUrgency,
                instruction: result.evDelta > 0 ? "Добавьте света" : "Убавьте света"
            ))
        }

        result.primaryInstruction = candidates.max(by: { $0.urgency < $1.urgency })?.instruction
            ?? "Кадр совпадает — можно снимать"

        return result
    }

    /// One clear pan verb. When both axes are meaningfully out, say "diagonal"
    /// rather than listing two competing corrections.
    private func panInstruction(dx: Double, dy: Double) -> String {
        let diagonal = abs(dx) > 0.5 * hypot(dx, dy) && abs(dy) > 0.5 * hypot(dx, dy)
        let horizontal = dx > 0 ? "вправо" : "влево"
        let vertical = dy > 0 ? "вниз" : "вверх"

        if diagonal {
            return "Сместите камеру по диагонали \(horizontal)-\(vertical)"
        }
        if abs(dx) >= abs(dy) {
            return "Сместите камеру \(horizontal)"
        }
        return "Сдвиньте камеру \(vertical)"
    }
}