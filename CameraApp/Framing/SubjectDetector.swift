import AVFoundation
import CoreGraphics
import Foundation
import Vision

/// Finds *what* is worth keeping in the frame, in priority order:
/// faces → people → salient objects → attention saliency → brightest area.
///
/// Everything runs on-device through Vision; nothing leaves the phone.
final class SubjectDetector {
    struct Options {
        var runPersonSegmentation = true
        var runHorizon = true
        /// Skip the expensive stages — used by the live-matching loop.
        var fast = false
    }

    /// Downscaled frame the analysis runs on.
    struct Input {
        let cgImage: CGImage
        let width: Int
        let height: Int
    }

    struct Output {
        var subject: SubjectInfo
        var saliencyMap: [Float]?
        var subjectMap: [Float]?
        var rollDegrees: Double
    }

    func analyze(_ input: Input, options: Options = Options()) async -> Output {
        var subject = SubjectInfo()
        var saliency: [Float]?
        var mask: [Float]?
        var roll: Double = 0

        // MARK: Faces — highest priority signal.
        var eyeYs: [CGFloat] = []
        var facingVectors: [CGVector] = []
        let faceRequest = VNDetectFaceRectanglesRequest()
        do {
            let handler = VNImageRequestHandler(cgImage: input.cgImage, orientation: .up, options: [:])
            try handler.perform([faceRequest])
            let faces = faceRequest.results ?? []
            subject.faceCount = faces.count
            for face in faces {
                // Vision uses a bottom-left origin; the engine works top-left.
                let box = Self.flip(face.boundingBox)
                guard let existing = subject.bounds {
                    subject.bounds = existing.union(box)
                } else {
                    subject.bounds = box
                }
                if let landmarks = face.landmarks,
                   let leftEye = landmarks.leftEye, leftEye.pointCount > 0,
                   let rightEye = landmarks.rightEye, rightEye.pointCount > 0 {
                    // Average the eye landmarks to get a stable eye line.
                    var eyeY: CGFloat = 0
                    for p in 0..<leftEye.pointCount { eyeY += leftEye.normalizedPoints[p].y }
                    for p in 0..<rightEye.pointCount { eyeY += rightEye.normalizedPoints[p].y }
                    eyeY /= CGFloat(leftEye.pointCount + rightEye.pointCount)
                    eyeYs.append(Self.flipY(eyeY))

                    // Nose tip offset from the eye midpoint gives a crude
                    // "which way is the face turned" vector for leadroom.
                    if let nose = landmarks.nose, nose.pointCount > 0 {
                        let nosePoint = nose.normalizedPoints[0]
                        let eyeMidX = (leftEye.normalizedPoints[0].x + rightEye.normalizedPoints[0].x) / 2
                        let eyeMidYValue = eyeY
                        facingVectors.append(
                            CGVector(dx: nosePoint.x - eyeMidX, dy: nosePoint.y - eyeMidYValue)
                        )
                    }
                }
            }
            if let bounds = subject.bounds {
                subject.kind = .face
                subject.centroid = CGPoint(x: bounds.midX, y: bounds.midY)
                if !eyeYs.isEmpty {
                    subject.eyeLineY = eyeYs.reduce(0, +) / CGFloat(eyeYs.count)
                }
                subject.facing = Self.average(facingVectors)
                subject.confidence = min(1.0, 0.75 + 0.1 * Double(faces.count))
            }
        } catch {
            // Face detection is best-effort; fall through to saliency.
        }

        // MARK: Attention saliency — always useful, cheap enough for live use.
        var salientObjects: [VNRectangleObservation] = []
        let attention = VNGenerateAttentionBasedSaliencyImageRequest()
        let objectness = VNGenerateObjectnessBasedSaliencyImageRequest()
        var requests: [VNRequest] = [attention]
        if !options.fast { requests.append(objectness) }

        do {
            let handler = VNImageRequestHandler(cgImage: input.cgImage, orientation: .up, options: [:])
            try handler.perform(requests)

            if let observation = attention.results?.first as? VNImageBasedSaliencyImageObservation,
               let buffer = observation.pixelBuffer {
                saliency = Self.normalize(buffer: buffer, width: input.width, height: input.height)
            }
            if let observation = objectness.results?.first as? VNImageBasedSaliencyImageObservation,
               let buffer = observation.pixelBuffer {
                let objectnessMap = Self.normalize(buffer: buffer, width: input.width, height: input.height)
                salientObjects = observation.salientObjects ?? []
                if subject.isEmpty, let box = Self.union(of: salientObjects) {
                    subject = SubjectInfo(
                        kind: .object,
                        bounds: Self.flip(box),
                        centroid: nil,
                        eyeLineY: nil,
                        facing: nil,
                        faceCount: 0,
                        confidence: 0.5
                    )
                    if let b = subject.bounds {
                        subject.centroid = CGPoint(x: b.midX, y: b.midY)
                    }
                }
                // Blend objectness into attention: it is sharper on actual objects.
                if let objectnessMap, let saliency {
                    mask = nil
                    saliency = zip(saliency, objectnessMap).map { a, b in
                        Float(min(1.0, Double(a) * 0.6 + Double(b) * 0.4))
                    }
                }
            }
        } catch {
            // Saliency unavailable — fall back to luminance-based subject detection.
        }

        // MARK: People — accurate but expensive, so only on the explicit scan.
        if subject.kind < .person && options.runPersonSegmentation && !options.fast {
            let segmentation = VNGeneratePersonSegmentationRequest()
            segmentation.qualityLevel = .fast
            segmentation.outputPixelFormat = kCVPixelFormatType_OneComponent8
            do {
                let handler = VNImageRequestHandler(cgImage: input.cgImage, orientation: .up, options: [:])
                try handler.perform([segmentation])
                if let observation = segmentation.results?.first as? VNPixelBufferObservation,
                   let buffer = observation.pixelBuffer {
                    let personMap = Self.normalize(buffer: buffer, width: input.width, height: input.height)
                    mask = personMap
                    if let box = Self.boundingBox(ofValues: personMap, threshold: 0.35, width: input.width, height: input.height) {
                        subject = SubjectInfo(
                            kind: .person,
                            bounds: box,
                            centroid: nil,
                            eyeLineY: nil,
                            facing: nil,
                            faceCount: subject.faceCount,
                            confidence: 0.85
                        )
                        subject.centroid = CGPoint(x: box.midX, y: box.midY)
                    }
                }
            } catch {
                // Segmentation is optional.
            }
        }

        // MARK: Horizon — free level correction.
        if options.runHorizon {
            let horizonRequest = VNDetectHorizonRequest()
            do {
                let handler = VNImageRequestHandler(cgImage: input.cgImage, orientation: .up, options: [:])
                try handler.perform([horizonRequest])
                if let observation = horizonRequest.results?.first {
                    roll = Double(observation.angle)
                }
            } catch {
                roll = 0
            }
        }

        return Output(subject: subject, saliencyMap: saliency, subjectMap: mask, rollDegrees: roll)
    }

    // MARK: - Helpers

    /// Vision: origin bottom-left. Engine: origin top-left.
    private static func flip(_ r: CGRect) -> CGRect {
        CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height)
    }

    private static func flipY(_ y: CGFloat) -> CGFloat {
        1 - y
    }

    private static func average(_ vectors: [CGVector]) -> CGVector? {
        guard !vectors.isEmpty else { return nil }
        let dx = vectors.reduce(0) { $0 + $1.dx } / CGFloat(vectors.count)
        let dy = vectors.reduce(0) { $0 + $1.dy } / CGFloat(vectors.count)
        guard hypot(dx, dy) > 0.01 else { return nil }
        return CGVector(dx: dx / hypot(dx, dy), dy: dy / hypot(dx, dy))
    }

    private static func union(of rects: [VNRectangleObservation]) -> CGRect? {
        guard !rects.isEmpty else { return nil }
        return rects.reduce(CGRect.null) { $0.union($1.boundingBox) }
    }

    /// Reads a single-channel Vision pixel buffer and normalises it to 0…1.
    static func normalize(buffer: CVPixelBuffer, width: Int, height: Int) -> [Float]? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        let sourceWidth = CVPixelBufferGetWidth(buffer)
        let sourceHeight = CVPixelBufferGetHeight(buffer)
        guard sourceWidth > 0, sourceHeight > 0,
              let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }

// Vision returns Float32 saliency maps; OneComponent8 is used by segmentation.
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        var maxValue: Float = 0

        var raw = [Float](repeating: 0, count: sourceWidth * sourceHeight)
        let format = CVPixelBufferGetPixelFormatType(buffer)
        if format == kCVPixelFormatType_OneComponent8 {
            let ptr = base.assumingMemoryBound(to: UInt8.self)
            for y in 0..<sourceHeight {
                let row = ptr.advanced(by: y * bytesPerRow)
                for x in 0..<sourceWidth {
                    let v = Float(row[x]) / 255.0
                    raw[y * sourceWidth + x] = v
                    maxValue = max(maxValue, v)
                }
            }
        } else {
            let ptr = base.assumingMemoryBound(to: Float.self)
            for y in 0..<sourceHeight {
                let row = ptr.advanced(by: y * bytesPerRow / MemoryLayout<Float>.size)
                for x in 0..<sourceWidth {
                    let v = row[x]
                    raw[y * sourceWidth + x] = v.isFinite ? v : 0
                    maxValue = max(maxValue, raw[y * sourceWidth + x])
                }
            }
        }

        // Normalise into 0…1.
        let scale: Float = maxValue > 0 ? 1 / maxValue : 1
        for i in 0..<raw.count { raw[i] = clamp(raw[i] * scale, 0, 1) }

        guard width != sourceWidth || height != sourceHeight else { return raw }
        return resample(raw, from: (sourceWidth, sourceHeight), to: (width, height))
    }

    /// Bilinear resample of a scalar map.
    static func resample(
        _ src: [Float],
        from srcSize: (Int, Int),
        to dstSize: (Int, Int)
    ) -> [Float] {
        let (sw, sh) = srcSize
        let (dw, dh) = dstSize
        guard sw > 0, sh > 0, dw > 0, dh > 0, src.count == sw * sh else {
            return [Float](repeating: 0, count: max(0, dw * dh))
        }
        var dst = [Float](repeating: 0, count: dw * dh)
        let scaleX = Double(sw) / Double(dw)
        let scaleY = Double(sh) / Double(dh)

        for y in 0..<dh {
            let sy = min(Double(sh - 1), (Double(y) + 0.5) * scaleY - 0.5)
            let y0 = max(0, Int(floor(sy)))
            let y1 = min(sh - 1, y0 + 1)
            let fy = Float(sy - Double(y0))

            for x in 0..<dw {
                let sx = min(Double(sw - 1), (Double(x) + 0.5) * scaleX - 0.5)
                let x0 = max(0, Int(floor(sx)))
                let x1 = min(sw - 1, x0 + 1)
                let fx = Float(sx - Double(x0))

                let v00 = src[y0 * sw + x0]
                let v10 = src[y0 * sw + x1]
                let v01 = src[y1 * sw + x0]
                let v11 = src[y1 * sw + x1]
                let top = v00 + (v10 - v00) * fx
                let bottom = v01 + (v11 - v01) * fx
                dst[y * dw + x] = top + (bottom - top) * fy
            }
        }
        return dst
    }

    /// Normalised bounding box of everything above `threshold`.
    static func boundingBox(
        ofValues values: [Float],
        threshold: Float,
        width: Int,
        height: Int
    ) -> CGRect? {
        var minX = width, minY = height, maxX = -1, maxY = -1
        for y in 0..<height {
            let row = y * width
            for x in 0..<width where values[row + x] >= threshold {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        guard maxX >= minX, maxY >= minY else { return nil }
        return CGRect(
            x: CGFloat(minX) / CGFloat(width),
            y: CGFloat(minY) / CGFloat(height),
            width: CGFloat(maxX - minX + 1) / CGFloat(width),
            height: CGFloat(maxY - minY + 1) / CGFloat(height)
        )
    }

    /// Weighted centroid of a scalar map — falls back to the geometric centre.
    static func centroid(
        ofValues values: [Float],
        width: Int,
        height: Int
    ) -> CGPoint? {
        var sum: Double = 0
        var sx: Double = 0
        var sy: Double = 0
        for y in 0..<height {
            let row = y * width
            for x in 0..<width {
                let w = Double(values[row + x])
                guard w > 0.01 else { continue }
                sum += w
                sx += Double(x) * w
                sy += Double(y) * w
            }
        }
        guard sum > 0 else { return nil }
        return CGPoint(
            x: CGFloat(sx / sum) / CGFloat(width),
            y: CGFloat(sy / sum) / CGFloat(height)
        )
    }
}