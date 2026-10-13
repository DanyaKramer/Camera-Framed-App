import AVFoundation
import CoreImage
import Foundation
import UIKit

/// Simulated depth of field, the same trick the stock camera uses.
///
/// iPhone apertures are fixed, so "f/2.8" here is a post-process: blur the far
/// field and keep the focus plane sharp. When the capture carries a real depth map
/// (`AVDepthData` from the dual camera or LiDAR) we blur by distance; otherwise we
/// fall back to a vignette-style blur that still reads as shallow depth of field.
///
/// This is explicitly an emulation — the UI labels it as such.
final class DepthOfFieldRenderer {
    private let context: CIContext

    init(context: CIContext) {
        self.context = context
    }

    /// Distance-aware blur.
    func render(image: CIImage, depthData: AVDepthData, blurRadius: Double) -> CIImage {
        // `depthDataMap` is non-optional on iOS 17.
        let depthMap = depthData.depthDataMap
        return depthAwareBlur(image: image, depthBuffer: depthMap, blurRadius: blurRadius)
    }

    /// Focus on the centre of the frame. Honest fallback when there is no depth map.
    func renderFallback(image: CIImage, blurRadius: Double) -> CIImage {
        let blurred = blurredLayer(image: image, radius: blurRadius)
        guard let mask = radialMask(in: image.extent) else { return blurred }

        // Masked variable blur keeps the centre sharp and falls off to the blurred layer.
        let filter = CIFilter(name: "CIMaskedVariableBlur")
        filter?.setValue(image, forKey: kCIInputImageKey)
        filter?.setValue(blurred, forKey: "InputBackgroundImage")
        filter?.setValue(mask, forKey: kCIInputMaskImageKey)
        filter?.setValue(max(blurRadius * 2.2, 2), forKey: kCIInputRadiusKey)
        return filter?.outputImage ?? image
    }

    // MARK: - Depth path

    private func depthAwareBlur(image: CIImage, depthBuffer: CVPixelBuffer, blurRadius: Double) -> CIImage {
        let width = CVPixelBufferGetWidth(depthBuffer)
        let height = CVPixelBufferGetHeight(depthBuffer)

        // Build a per-pixel "how much to blur" ramp: sharp near the focus distance,
        // fully blurred far away. Vision depth is disparity — larger = nearer.
        guard let maskImage = Self.makeDepthRamp(
            depthBuffer: depthBuffer,
            width: width,
            height: height,
            targetExtent: image.extent
        ) else {
            return renderFallback(image: image, blurRadius: blurRadius)
        }

        let blurred = blurredLayer(image: image, radius: blurRadius)

        let filter = CIFilter(name: "CIBlendWithMask")
        filter?.setValue(blurred, forKey: kCIInputImageKey)
        filter?.setValue(image, forKey: kCIInputBackgroundImageKey)
        filter?.setValue(maskImage, forKey: kCIInputMaskImageKey)
        return filter?.outputImage ?? image
    }

    /// Reads a depth/disparity buffer and produces a greyscale CIImage where
    /// white = in focus, black = fully blurred.
    nonisolated static func makeDepthRamp(
        depthBuffer: CVPixelBuffer,
        width: Int,
        height: Int,
        targetExtent: CGRect
    ) -> CIImage? {
        CVPixelBufferLockBaseAddress(depthBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(depthBuffer) else { return nil }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(depthBuffer)
        let isFloat = CVPixelBufferGetPixelFormatType(depthBuffer) == kCVPixelFormatType_DepthFloat32

        // Focus on the disparity at the centre of the frame.
        var centreValue: Float = 0
        if isFloat {
            let ptr = base.assumingMemoryBound(to: Float.self)
            let cx = width / 2
            let cy = height / 2
            let r = max(2, min(width, height) / 20)
            var sum: Float = 0
            var count = 0
            for y in stride(from: cy - r, to: cy + r, by: 2) where y >= 0 && y < height {
                for x in stride(from: cx - r, to: cx + r, by: 2) where x >= 0 && x < width {
                    let v = ptr[y * bytesPerRow / MemoryLayout<Float>.size + x]
                    guard v.isFinite else { continue }
                    sum += v
                    count += 1
                }
            }
            if count > 0 {
                centreValue = sum / Float(count)
            }
        }

        // Build an 8-bit ramp, downsampled to keep the filter cheap.
        let rampWidth = max(16, width / 2)
        let rampHeight = max(16, height / 2)
        var bytes = [UInt8](repeating: 255, count: rampWidth * rampHeight)

        if isFloat {
            let ptr = base.assumingMemoryBound(to: Float.self)
            for y in 0..<rampHeight {
                let sy = min(height - 1, y * 2)
                for x in 0..<rampWidth {
                    let sx = min(width - 1, x * 2)
                    let v = ptr[sy * bytesPerRow / MemoryLayout<Float>.size + sx]
                    guard v.isFinite else {
                        bytes[y * rampWidth + x] = 255
                        continue
                    }
                    // Ratio 1 → fully sharp; lower (farther away) → blurred.
                    let ratio = v / max(centreValue, 0.0001)
                    bytes[y * rampWidth + x] = UInt8(clamp((1.0 - (1.0 - ratio) * 1.8) * 255, 0, 255))
                }
            }
        }

        guard let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        guard let cgImage = CGImage(
            width: rampWidth,
            height: rampHeight,
            bitsPerComponent: 8,
            bitsPerPixel: 8,
            bytesPerRow: rampWidth,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        ) else { return nil }

        let mask = CIImage(cgImage: cgImage)
        return mask.transformed(
            by: CGAffineTransform(
                scaleX: targetExtent.width / CGFloat(rampWidth),
                y: targetExtent.height / CGFloat(rampHeight)
            )
        ).transformed(by: CGAffineTransform(translationX: targetExtent.minX, y: targetExtent.minY))
    }

    // MARK: - Shared

    private func blurredLayer(image: CIImage, radius: Double) -> CIImage {
        // Downscale → blur → upscale. Dramatically cheaper than a full-res blur
        // and visually indistinguishable for a background defocus.
        let extent = image.extent
        let scale = max(0.08, 28.0 / max(radius, 1))
        let small = image
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius * scale * 0.55])
            .transformed(by: CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
        return small.cropped(to: extent)
    }

    private func radialMask(in extent: CGRect) -> CIImage? {
        let center = CGPoint(x: extent.midX, y: extent.midY)
        let radius = max(extent.width, extent.height) * 0.42
        let filter = CIFilter(name: "CIRadialGradient")
        filter?.setValue(CIVector(cgPoint: center), forKey: "inputCenter")
        filter?.setValue(radius, forKey: "inputRadius0")
        filter?.setValue(radius * 1.6, forKey: "inputRadius1")
        filter?.setValue(CIColor.white, forKey: "inputColor0")
        filter?.setValue(CIColor.black, forKey: "inputColor1")
        return filter?.outputImage?.cropped(to: extent)
    }
}