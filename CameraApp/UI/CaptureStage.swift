import AVFoundation
import SwiftUI
import UIKit

/// Composition grid drawn **inside the capture mask only**.
///
/// Lines divide the crop, not the screen — which is what makes the third-lines
/// line up with what ends up in the photo.
struct GridOverlay: View {
    enum Style {
        case thirds
        case golden
        case diagonals
        case center
    }

    let style: Style
    let opacity: Double

    var body: some View {
        Canvas { context, size in
            let stroke = StrokeStyle(lineWidth: 0.7, lineCap: .round)

            switch style {
            case .thirds:
                drawLines(context: &context, size: size, fractions: [1.0 / 3.0, 2.0 / 3.0], stroke: stroke)
            case .golden:
                drawLines(context: &context, size: size, fractions: [0.382, 0.618], stroke: stroke)
            case .diagonals:
                var path = Path()
                path.move(to: .zero)
                path.addLine(to: CGPoint(x: size.width, y: size.height))
                path.move(to: CGPoint(x: size.width, y: 0))
                path.addLine(to: CGPoint(x: 0, y: size.height))
                drawLines(context: &context, size: size, fractions: [1.0 / 3.0, 2.0 / 3.0], stroke: stroke)
                context.stroke(path, with: .color(.white.opacity(opacity * 0.7)), style: stroke)
            case .center:
                var path = Path()
                path.move(to: CGPoint(x: size.width / 2, y: 0))
                path.addLine(to: CGPoint(x: size.width / 2, y: size.height))
                path.move(to: CGPoint(x: 0, y: size.height / 2))
                path.addLine(to: CGPoint(x: size.width, y: size.height / 2))
                context.stroke(path, with: .color(.white.opacity(opacity)), style: stroke)

                let c = CGPoint(x: size.width / 2, y: size.height / 2)
                let r: CGFloat = 8
                var box = Path()
                box.addRect(CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
                context.stroke(box, with: .color(.white.opacity(opacity)), style: stroke)
            }
        }
        .allowsHitTesting(false)
    }

    private func drawLines(
        context: inout GraphicsContext,
        size: CGSize,
        fractions: [CGFloat],
        stroke: StrokeStyle
    ) {
        var path = Path()
        for f in fractions {
            let x = size.width * f
            path.move(to: CGPoint(x: x, y: 0))
            path.addLine(to: CGPoint(x: x, y: size.height))

            let y = size.height * f
            path.move(to: CGPoint(x: 0, y: y))
            path.addLine(to: CGPoint(x: size.width, y: y))
        }
        context.stroke(path, with: .color(.white.opacity(opacity)), style: stroke)
    }
}

/// Dims everything outside the capture rectangle and outlines it.
struct AspectMask: View {
    let captureRect: CGRect
    var outlineWidth: CGFloat = 1
    var outlineColor: Color = .white.opacity(0.35)

    var body: some View {
        Canvas { context, size in
            // Even-odd fill of (outer rect ∪ capture rect) leaves exactly the ring
            // around the capture area filled.
            var ring = Path()
            ring.addRect(CGRect(origin: .zero, size: size))
            ring.addRect(captureRect)
            context.fill(ring, with: .color(.black.opacity(0.55)), style: FillStyle(eoFill: true))

            let border = Path(roundedRect: captureRect, cornerRadius: 3)
            context.stroke(border, with: .color(outlineColor), lineWidth: outlineWidth)
        }
        .allowsHitTesting(false)
    }
}

/// Geometry of the capture area, handed to overlay content so it can convert
/// framing-analysis coordinates (which are normalised to the *visible frame*)
/// into its own local space.
struct CaptureGeometry {
    /// Where the capture crop sits on screen.
    let captureRect: CGRect
    /// Where the whole sensor frame sits on screen (letterboxed by `.resizeAspect`).
    let videoRect: CGRect

    var size: CGSize { captureRect.size }

    /// Rect normalised to the visible frame → rect normalised to the capture crop.
    func toLocal(_ rect: CGRect) -> CGRect {
        CGRect(
            x: (rect.minX - captureRect.minX) / max(captureRect.width, 1),
            y: (rect.minY - captureRect.minY) / max(captureRect.height, 1),
            width: rect.width / max(captureRect.width, 1),
            height: rect.height / max(captureRect.height, 1)
        )
    }

    func toLocal(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: (point.x - captureRect.minX) / max(captureRect.width, 1),
            y: (point.y - captureRect.minY) / max(captureRect.height, 1)
        )
    }

    /// Unit-square → absolute points inside the capture crop.
    func point(_ unit: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: unit.x * size.width, y: unit.y * size.height)
    }

    func rect(_ unit: CGRect, in size: CGSize) -> CGRect {
        CGRect(
            x: unit.minX * size.width,
            y: unit.minY * size.height,
            width: unit.width * size.width,
            height: unit.height * size.height
        )
    }
}

/// A camera-output frame with the mask, grid and level tool layered on top.
struct CaptureStage<Content: View>: View {
    let session: AVCaptureSession
    let bufferAspect: CGFloat
    let aspect: AspectRatio
    let gridStyle: GridStyle
    let gridOpacity: Double
    var rollDegrees: Double = 0
    var showLevel: Bool = false
    /// Called with a point in the preview layer's coordinate space.
    var onTapAtLayerPoint: ((CGPoint) -> Void)?
    /// Called once the preview layer exists, so taps can be converted to device points.
    var onPreviewLayerReady: ((AVCaptureVideoPreviewLayer?) -> Void)?
    /// Extra overlay content, positioned relative to the capture rect.
    @ViewBuilder var content: (CaptureGeometry) -> Content

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            // 1. Where the whole sensor frame sits on screen.
            let videoRect = CGRect.originCentered(aspect: bufferAspect, in: size)
            // 2. Where the capture crop sits inside it.
            let captureRect = CGRect.largestWithAspect(aspect.ratio, in: videoRect)
            let geometry = CaptureGeometry(captureRect: captureRect, videoRect: videoRect)

            ZStack {
                PreviewView(session: session, onLayerReady: onPreviewLayerReady)
                    .ignoresSafeArea()

                AspectMask(captureRect: captureRect)

                if gridStyle != .off {
                    GridOverlay(
                        style: switchGrid(gridStyle),
                        opacity: gridOpacity
                    )
                    .frame(width: captureRect.width, height: captureRect.height)
                    .position(x: captureRect.midX, y: captureRect.midY)
                }

                if showLevel {
                    LevelIndicator(rollDegrees: rollDegrees)
                        .frame(width: captureRect.width, height: captureRect.height)
                        .position(x: captureRect.midX, y: captureRect.midY)
                }

                content(geometry)
                    .frame(width: captureRect.width, height: captureRect.height)
                    .position(x: captureRect.midX, y: captureRect.midY)
            }
            .frame(width: size.width, height: size.height)
            .contentShape(Rectangle())
            .gesture(
                SpatialTapGesture().onEnded { value in
                    onTapAtLayerPoint?(value.location)
                }
            )
        }
    }

    private func switchGrid(_ style: GridStyle) -> GridOverlay.Style {
        switch style {
        case .off: .thirds
        case .thirds: .thirds
        case .golden: .golden
        case .diagonals: .diagonals
        case .center: .center
        }
    }
}

/// Horizon reference line — the rule-of-thirds rule people actually forget.
struct LevelIndicator: View {
    let rollDegrees: Double

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let isLevel = abs(rollDegrees) < 0.8

            ZStack {
                // Fixed reference.
                Rectangle()
                    .fill(Color.white.opacity(0.25))
                    .frame(width: width * 0.32, height: 1)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)

                // Live horizon, rotated.
                Rectangle()
                    .fill(isLevel ? Color.green.opacity(0.95) : Color.yellow.opacity(0.9))
                    .frame(width: width * 0.26, height: 2)
                    .rotationEffect(.degrees(rollDegrees))
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
        }
        .allowsHitTesting(false)
    }
}

extension CGRect {
    /// Largest rect with `aspect` (w/h) centred inside `size`.
    static func originCentered(aspect: CGFloat, in size: CGSize) -> CGRect {
        largestWithAspect(aspect, in: CGRect(origin: .zero, size: size))
    }
}