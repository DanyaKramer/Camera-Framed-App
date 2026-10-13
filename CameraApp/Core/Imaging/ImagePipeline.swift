import AVFoundation
import CoreImage
import Foundation
import UIKit

/// Post-capture pipeline: aspect crop → optional depth-of-field → orientation.
final class ImagePipeline {
    private let context = CIContext(options: [.useSoftwareRenderer: false])
    private let dof = DepthOfFieldRenderer(context: context)

    func process(
        _ captured: CapturedPhoto,
        aspect: AspectRatio,
        depthOfField: Bool,
        aperture: Double
    ) async -> CapturedPhoto {
        var result = captured
        result.aspect = aspect

        guard let ci = CIImage(image: captured.image) else {
            return result
        }

        var image = ci

        // 1. Aspect crop — this is the WYSIWYG guarantee.
        image = Self.crop(image: image, to: aspect)

        // 2. Simulated depth of field from the f-stop the user selected.
        if depthOfField {
            let blurRadius = Self.blurRadius(forAperture: aperture, reference: 1.8)
            if blurRadius > 0.6 {
                if let depth = captured.depthData {
                    image = dof.render(image: image, depthData: depth, blurRadius: blurRadius)
                } else {
                    image = dof.renderFallback(image: image, blurRadius: blurRadius)
                }
            }
        }

        // 3. Back to UIImage.
        guard let cgImage = context.createCGImage(image, from: image.extent) else {
            return result
        }
        result.image = UIImage(cgImage: cgImage)
        return result
    }

    /// Largest centre crop with the requested aspect.
    static func crop(image: CIImage, to aspect: AspectRatio) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        let currentRatio = extent.width / extent.height
        let target = aspect.ratio

        if abs(currentRatio - target) < 0.005 { return image }

        var rect = extent
        if currentRatio > target {
            // Too wide — trim the sides.
            let newWidth = extent.height * target
            rect = CGRect(
                x: extent.midX - newWidth / 2,
                y: extent.minY,
                width: newWidth,
                height: extent.height
            )
        } else {
            // Too tall — trim top and bottom.
            let newHeight = extent.width / target
            rect = CGRect(
                x: extent.minX,
                y: extent.midY - newHeight / 2,
                width: extent.width,
                height: newHeight
            )
        }
        return image.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
    }

    /// Each full stop of aperture ≈ doubles the blur radius, past ~f/2.8.
    /// Below the physical aperture there is nothing left to close.
    static func blurRadius(forAperture aperture: Double, reference: Double) -> Double {
        let stops = max(0, log2(max(aperture, 0.1) / max(reference, 0.1)))
        return min(stops * 9.0, 70.0)
    }
}