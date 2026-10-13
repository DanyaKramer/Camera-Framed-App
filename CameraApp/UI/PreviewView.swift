import AVFoundation
import SwiftUI
import UIKit

/// Hosts `AVCaptureVideoPreviewLayer`.
///
/// `videoGravity = .resizeAspect` is deliberate: the whole sensor frame is visible,
/// so the composition mask, the grid and the framing analysis all share one
/// coordinate space and the preview is honest WYSIWYG.
struct PreviewView: UIViewRepresentable {
    let session: AVCaptureSession
    /// Hands the layer out so callers can convert layer points into capture-device
    /// points with `captureDevicePointConverted(fromLayerPoint:)`.
    var onLayerReady: ((AVCaptureVideoPreviewLayer?) -> Void)?

    func makeUIView(context: Context) -> PreviewContainerView {
        let view = PreviewContainerView()
        view.backgroundColor = .black
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect
        context.coordinator.onLayerReady = onLayerReady
        onLayerReady?(view.previewLayer)
        return view
    }

    func updateUIView(_ uiView: PreviewContainerView, context: Context) {
        if uiView.previewLayer.session !== session {
            uiView.previewLayer.session = session
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onLayerReady: onLayerReady)
    }

    final class Coordinator {
        var onLayerReady: ((AVCaptureVideoPreviewLayer?) -> Void)?
        init(onLayerReady: ((AVCaptureVideoPreviewLayer?) -> Void)?) {
            self.onLayerReady = onLayerReady
        }
    }
}

final class PreviewContainerView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }

    var previewLayer: AVCaptureVideoPreviewLayer {
        // Safe: `layerClass` guarantees the type.
        layer as! AVCaptureVideoPreviewLayer
    }
}