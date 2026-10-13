import AVFoundation
import CoreImage
import CoreVideo
import Foundation
import UIKit

/// Orchestrates one analysis pass over a video frame.
///
/// Pipeline:
///   pixel buffer → small CGImage → Vision (saliency / subject / horizon)
///   → cost maps → crop search → metering → analysis
///
/// Cost: ~80 ms on current hardware for the full pass, ~35 ms in `.fast` mode.
final class FramingEngine {
    struct Configuration {
        /// Long edge of the downscaled analysis image.
        var analysisLongEdge: Int = 192
        var fastAnalysisLongEdge: Int = 128
        var weights = CropScoreWeights.default
        var searcherConfig = CropSearcher.Config()
        var runPersonSegmentationOnScan = true
    }

    private let config: Configuration
    private let detector = SubjectDetector()
    private let detectorOptions: SubjectDetector.Options

    init(config: Configuration = Configuration(), detectorOptions: SubjectDetector.Options = SubjectDetector.Options()) {
        self.config = config
        self.detectorOptions = detectorOptions
    }

    // MARK: - Public entry points

    /// Full analysis for the explicit Scan button.
    func scan(
        frame: FrameStreamer.Frame,
        aspect: AspectRatio,
        zoom: CGFloat,
        minZoom: CGFloat,
        maxZoom: CGFloat
    ) async -> FramingAnalysis? {
        await analyze(
            frame: frame,
            aspect: aspect,
            zoom: zoom,
            minZoom: minZoom,
            maxZoom: maxZoom,
            mode: .full
        )
    }

    /// Cheap analysis for the live matching loop.
    func analyzeLive(
        frame: FrameStreamer.Frame,
        aspect: AspectRatio,
        zoom: CGFloat
    ) async -> FramingAnalysis? {
        await analyze(
            frame: frame,
            aspect: aspect,
            zoom: zoom,
            minZoom: 1,
            maxZoom: .greatestFiniteMagnitude,
            mode: .fast
        )
    }

    enum Mode {
        case full
        case fast
    }

    // MARK: - Core

    private func analyze(
        frame: FrameStreamer.Frame,
        aspect: AspectRatio,
        zoom: CGFloat,
        minZoom: CGFloat,
        maxZoom: CGFloat,
        mode: Mode
    ) async -> FramingAnalysis? {
        let longEdge = mode == .full ? config.analysisLongEdge : config.fastAnalysisLongEdge
        guard let prepared = Self.prepare(frame.pixelBuffer, longEdge: longEdge) else { return nil }

        let input = SubjectDetector.Input(
            cgImage: prepared.cgImage,
            width: prepared.width,
            height: prepared.height
        )

        var options = detectorOptions
        options.fast = (mode == .fast)
        options.runPersonSegmentation = (mode == .full) && config.runPersonSegmentationOnScan

        let output = await detector.analyze(input, options: options)

        // Build cost maps.
        let maps = Self.makeCostMaps(
            luminance: prepared.luminance,
            saliency: output.saliencyMap,
            subjectMask: output.subjectMap,
            width: prepared.width,
            height: prepared.height
        )

        // Search.
        var searcherConfig = config.searcherConfig
        // Bound the search by what the hardware can actually zoom to.
        searcherConfig.minHeightFraction = 1 / CGFloat(max(maxZoom, 1.01))
        searcherConfig.minWidthFraction = minZoom / CGFloat(max(maxZoom, 1.01))
        let searcher = CropSearcher(config: searcherConfig)

        let candidate = searcher.search(
            maps: maps,
            aspect: aspect,
            subject: output.subject,
            rollDegrees: output.rollDegrees,
            weights: config.weights
        )

        let crop = candidate?.rect ?? CropSearcher.visibleCrop(
            currentZoom: zoom, frameAspect: maps.aspect, aspect: aspect
        )

        let metering = Metering.measure(
            luminanceMap: prepared.luminance,
            width: prepared.width,
            height: prepared.height,
            crop: crop
        )

        return FramingAnalysis(
            crop: crop,
            aspect: aspect,
            score: candidate?.score.total ?? 0,
            scoreComponents: candidate?.score.components ?? [:],
            subject: output.subject,
            rollDegrees: output.rollDegrees,
            meanLuminance: metering?.meanLuminance ?? 0.5,
            clippedFraction: metering?.clippedFraction ?? 0,
            evAdjustment: metering?.evAdjustment ?? 0,
            subjectBounds: output.subject.bounds
        )
    }

    // MARK: - Preparation

    struct Prepared {
        let cgImage: CGImage
        let luminance: [Float]
        let width: Int
        let height: Int
    }

    /// Downscales the Y plane of the camera buffer and builds a CGImage for Vision.
    ///
    /// The camera delivers 420YpCbCr bi-planar frames. The Y plane *is* luma, so
    /// it is read directly — no colour conversion needed for metering or edges.
    nonisolated static func prepare(_ pixelBuffer: CVPixelBuffer, longEdge: Int) -> Prepared? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 8, height > 8 else { return nil }

        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let isPlanarY = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        let isOneComponent8 = format == kCVPixelFormatType_OneComponent8
        let isBGRA = format == kCVPixelFormatType_32BGRA

        guard isPlanarY || isOneComponent8 || isBGRA else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        // Source luma, sampled on the way down.
        let srcW = width
        let srcH = height
        let scale = Double(longEdge) / Double(max(srcW, srcH))
        let dstW = max(16, Int((Double(srcW) * scale).rounded()))
        let dstH = max(16, Int((Double(srcH) * scale).rounded()))

        var luma = [Float](repeating: 0, count: dstW * dstH)

        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }

        if isPlanarY {
            let ptr = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<dstH {
                let sy = min(srcH - 1, Int((Double(y) + 0.5) / Double(dstH) * Double(srcH)))
                let row = ptr.advanced(by: sy * bytesPerRow)
                let rowBase = y * dstW
                for x in 0..<dstW {
                    let sx = min(srcW - 1, Int((Double(x) + 0.5) / Double(dstW) * Double(srcW)))
                    luma[rowBase + x] = Float(row[sx]) / 255.0
                }
            }
        } else if isOneComponent8 {
            let ptr = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<dstH {
                let sy = min(srcH - 1, Int((Double(y) + 0.5) / Double(dstH) * Double(srcH)))
                let row = ptr.advanced(by: sy * bytesPerRow)
                let rowBase = y * dstW
                for x in 0..<dstW {
                    let sx = min(srcW - 1, Int((Double(x) + 0.5) / Double(dstW) * Double(srcW)))
                    luma[rowBase + x] = Float(row[sx]) / 255.0
                }
            }
        } else {
            // BGRA — Rec.601 luma from BGR.
            let ptr = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<dstH {
                let sy = min(srcH - 1, Int((Double(y) + 0.5) / Double(dstH) * Double(srcH)))
                let row = ptr.advanced(by: sy * bytesPerRow)
                let rowBase = y * dstW
                for x in 0..<dstW {
                    let sx = min(srcW - 1, Int((Double(x) + 0.5) / Double(dstW) * Double(srcW)))
                    let p = row.advanced(by: sx * 4)
                    let b = Double(p[0]), g = Double(p[1]), r = Double(p[2])
                    let l = (0.299 * r + 0.587 * g + 0.114 * b) / 255.0
                    luma[rowBase + x] = Float(l)
                }
            }
        }

        // Hand Vision an 8-bit grey CGImage — Vision does its own preprocessing
        // and this is the cheapest reliable input.
        var grey = [UInt8](repeating: 0, count: dstW * dstH)
        for i in 0..<luma.count {
            grey[i] = UInt8(clamp(luma[i], 0, 1) * 255)
        }

        guard let provider = CGDataProvider(data: Data(grey) as CFData) else { return nil }
        guard let cgImage = CGImage(
            width: dstW,
            height: dstH,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: dstW,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else { return nil }

        return Prepared(cgImage: cgImage, luminance: luma, width: dstW, height: dstH)
    }

    // MARK: - Cost maps

    nonisolated static func makeCostMaps(
        luminance: [Float],
        saliency: [Float]?,
        subjectMask: [Float]?,
        width: Int,
        height: Int
    ) -> CostMaps {
        // Edges: Sobel magnitude on the luma map, normalised.
        var edges = [Float](repeating: 0, count: width * height)
        for y in 1..<(height - 1) {
            let row = y * width
            let up = row - width
            let down = row + width
            for x in 1..<(width - 1) {
                let gx = -luminance[up + x - 1] + luminance[up + x + 1]
                    - 2 * luminance[row + x - 1] + 2 * luminance[row + x + 1]
                    - luminance[down + x - 1] + luminance[down + x + 1]
                let gy = -luminance[up + x - 1] - 2 * luminance[up + x] - luminance[up + x + 1]
                    + luminance[down + x - 1] + 2 * luminance[down + x] + luminance[down + x + 1]
                edges[row + x] = clamp((abs(gx) + abs(gy)) * 0.25, 0, 1)
            }
        }

        var clipped = [Float](repeating: 0, count: width * height)
        for i in 0..<luminance.count {
            clipped[i] = luminance[i] >= 0.985 ? 1 : 0
        }

        // Saliency fallback: local contrast stands in when Vision gives us nothing.
        let effectiveSaliency: [Float]
        if let saliency, saliency.count == width * height {
            effectiveSaliency = saliency
        } else {
            effectiveSaliency = localContrast(luminance: luminance, width: width, height: height)
        }

        // Subject mask fallback: threshold the saliency.
        let effectiveSubject: [Float]
        if let subjectMask, subjectMask.count == width * height {
            effectiveSubject = subjectMask
        } else {
            var mask = [Float](repeating: 0, count: width * height)
            let threshold: Float = 0.45
            for i in 0..<effectiveSaliency.count where effectiveSaliency[i] >= threshold {
                mask[i] = 1
            }
            effectiveSubject = mask
        }

        func integral(_ values: [Float]) -> IntegralImage {
            IntegralImage(values: values, width: width, height: height)
        }

        return CostMaps(
            width: width,
            height: height,
            saliency: integral(effectiveSaliency),
            subject: integral(effectiveSubject),
            luminance: integral(luminance),
            clipped: integral(clipped),
            edge: integral(edges)
        )
    }

    /// Cheap "what stands out" map: absolute deviation from a local mean.
    nonisolated private static func localContrast(
        luminance: [Float],
        width: Int,
        height: Int
    ) -> [Float] {
        let radius = max(2, min(width, height) / 12)
        var out = [Float](repeating: 0, count: width * height)

        for y in 0..<height {
            let y0 = max(0, y - radius)
            let y1 = min(height - 1, y + radius)
            for x in 0..<width {
                let x0 = max(0, x - radius)
                let x1 = min(width - 1, x + radius)
                var sum: Float = 0
                var count: Float = 0
                var yy = y0
                while yy <= y1 {
                    var xx = x0
                    let row = yy * width
                    while xx <= x1 {
                        sum += luminance[row + xx]
                        count += 1
                        xx += 1
                    }
                    yy += 1
                }
                guard count > 0 else { continue }
                let mean = sum / count
                out[y * width + x] = clamp(abs(luminance[y * width + x] - mean) * 3.0, 0, 1)
            }
        }
        return out
    }
}