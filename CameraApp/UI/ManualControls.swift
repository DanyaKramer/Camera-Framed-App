import SwiftUI

/// Vertical fader for one exposure parameter.
struct ExposureFader: View {
    let title: String
    let valueLabel: String
    /// Normalised position, 0 (bottom) … 1 (top).
    let position: Double
    let isActive: Bool
    var isAdjusted: Bool = false
    let onCommit: (Double) -> Void

    @State private var dragging: Bool = false

    var body: some View {
        GeometryReader { geo in
            let height = geo.size.height

            ZStack {
                Capsule()
                    .fill(.black.opacity(0.45))
                    .frame(width: 62)

                Capsule()
                    .strokeBorder(.white.opacity(0.28), lineWidth: 0.8)
                    .frame(width: 62)

                // Track fill from the bottom to the current value.
                VStack {
                    Spacer()
                    Rectangle()
                        .fill(isActive ? Color.white.opacity(0.18) : Color.white.opacity(0.08))
                        .frame(height: max(4, height * position))
                }
                .frame(width: 62)
                .clipShape(Capsule())

                VStack(spacing: 2) {
                    Text(title)
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white.opacity(0.7))
                    Text(valueLabel)
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                        .foregroundStyle(isAdjusted ? Color.orange : .white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }
                .frame(width: 58)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !dragging { dragging = true }
                        let raw = 1.0 - Double(value.location.y / max(height, 1))
                        onCommit(clamp(raw, 0, 1))
                    }
                    .onEnded { _ in dragging = false }
            )
        }
        .frame(width: 62, height: 190)
    }
}

/// Live luminance histogram with clipping indicators.
struct HistogramView: View {
    /// 64 bins, 0…1.
    let bins: [Double]
    var tint: Color = .white

    var body: some View {
        Canvas { context, size in
            guard bins.count > 1 else { return }
            let maxValue = max(bins.max() ?? 1, 0.0001)
            let barWidth = size.width / CGFloat(bins.count)

            for (index, value) in bins.enumerated() {
                let normalized = value / maxValue
                let h = max(1, size.height * CGFloat(normalized))
                let rect = CGRect(
                    x: CGFloat(index) * barWidth,
                    y: size.height - h,
                    width: max(1, barWidth - 0.5),
                    height: h
                )
                let isClipped = index >= bins.count - 3
                context.fill(
                    Path(rect),
                    with: .color(isClipped ? Color.red.opacity(0.85) : tint.opacity(0.9))
                )
            }
        }
        .frame(height: 46)
        .allowsHitTesting(false)
    }
}

/// Manual mode: three faders + the exposure triangle readout.
@MainActor
struct ManualControlsPanel: View {
    let controller: CameraController

    /// Normalised 0…1 position of a value inside its range.
    private func position(_ value: Double, in range: ClosedRange<Double>) -> Double {
        let span = range.upperBound - range.lowerBound
        guard span > 0 else { return 0 }
        return clamp((value - range.lowerBound) / span, 0, 1)
    }

    private func value(_ normalized: Double, in range: ClosedRange<Double>) -> Double {
        range.lowerBound + normalized * (range.upperBound - range.lowerBound)
    }

    var body: some View {
        VStack(spacing: 8) {
            if controller.settings.showHistogram {
                HistogramView(bins: controller.histogramBins)
                    .padding(.horizontal, 40)
            }
            HStack(alignment: .bottom, spacing: 14) {
                faders
                ExposureReadout(controller: controller)
                    .padding(.bottom, 6)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
        }
    }

    @ViewBuilder
    private var faders: some View {
        HStack(spacing: 10) {
            // Aperture — simulated, drives exposure and bokeh.
            ExposureFader(
                title: "ƒ",
                valueLabel: String(format: "%.1f", controller.selectedAperture),
                position: position(
                    controller.selectedAperture,
                    in: (controller.apertureSteps.first ?? 1.4)...(controller.apertureSteps.last ?? 16)
                ),
                isActive: controller.selectedAperture > controller.device.realAperture + 0.01,
                isAdjusted: controller.selectedAperture != controller.device.realAperture
            ) { normalized in
                let range = (controller.apertureSteps.first ?? 1.4)...(controller.apertureSteps.last ?? 16)
                controller.setAperture((value(normalized, in: range) * 10).rounded() / 10)
            }

            // Shutter.
            let shutterRange = (controller.shutterSteps.first ?? 1.0 / 8000)...(controller.shutterSteps.last ?? 4)
            ExposureFader(
                title: "Выдержка",
                valueLabel: ExposureParams(duration: controller.manualDuration, iso: 0).stopLabel,
                position: position(controller.manualDuration, in: shutterRange),
                isActive: controller.exposureFixed,
                isAdjusted: controller.exposureFixed
            ) { normalized in
                let target = value(normalized, in: shutterRange)
                // Snap to the nearest 1/3-stop step.
                let steps = controller.shutterSteps
                guard !steps.isEmpty else { return }
                let nearest = steps.min(by: { abs($0 - target) < abs($1 - target) }) ?? target
                controller.setShutter(nearest)
            }

            // ISO.
            let isoRange = Double(controller.isoSteps.first ?? 25)...Double(controller.isoSteps.last ?? 6400)
            ExposureFader(
                title: "ISO",
                valueLabel: "\(Int(controller.manualISO))",
                position: position(Double(controller.manualISO), in: isoRange),
                isActive: controller.exposureFixed,
                isAdjusted: controller.exposureFixed
            ) { normalized in
                let target = value(normalized, in: isoRange)
                let steps = controller.isoSteps
                guard !steps.isEmpty else { return }
                let nearest = steps.min(by: { abs(Double($0) - target) < abs(Double($1) - target) }) ?? Float(target)
                controller.setISO(nearest)
            }
        }
    }
}

/// Read-only strip explaining what the hardware is actually doing.
@MainActor
struct ExposureReadout: View {
    let controller: CameraController

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            row("Объектив", CameraDeviceController.fNumberLabel(Float(controller.device.realAperture)))
            row("Диапазон ISO", "\(Int(controller.device.limits.minISO))–\(Int(controller.device.limits.maxISO))")
            row("Выдержка", ExposureParams(
                duration: controller.device.limits.minDuration, iso: 0
            ).stopLabel + " … " + ExposureParams(
                duration: controller.device.limits.maxDuration, iso: 0
            ).stopLabel)
            row("Компенсация ƒ", String(format: "%+.1f EV", controller.apertureCompensationEV))
        }
        .font(.system(size: 10, design: .monospaced))
        .foregroundStyle(.white.opacity(0.65))
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
            Spacer(minLength: 8)
            Text(value)
        }
    }
}