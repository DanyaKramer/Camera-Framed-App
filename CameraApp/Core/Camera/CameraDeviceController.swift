import AVFoundation
import Foundation

/// Camera device controls: zoom, focus, exposure, white balance, torch.
///
/// Every mutation runs on the capture session's queue with the device locked.
@MainActor
@Observable
final class CameraDeviceController {
    private let session: CameraSessionController
    private let verifier = ExposureVerifier()

    // Published state
    private(set) var zoomFactor: CGFloat = 1
    private(set) var minZoom: CGFloat = 1
    private(set) var maxZoom: CGFloat = 1
    private(set) var realAperture: Double = 1.78
    private(set) var lensApertureLabel: String = "f/1.8"
    private(set) var isAEAFLocked = false
    private(set) var isTorchOn = false
    private(set) var isTorchAvailable = false
    private(set) var limits: ExposureClamper.Limits = .unknown
    private(set) var currentExposure = ExposureParams.identity

    var onExposureChanged: ((ExposureParams) -> Void)?

    init(session: CameraSessionController) {
        self.session = session
    }

    func adopt(device: AVCaptureDevice) {
        limits = ExposureClamper.limits(for: device)
        realAperture = Double(device.lensAperture)
        lensApertureLabel = Self.fNumberLabel(device.lensAperture)
        isTorchAvailable = device.hasTorch && device.isTorchAvailable

        minZoom = device.minAvailableVideoZoomFactor
        maxZoom = min(device.maxAvailableVideoZoomFactor, 12)
        zoomFactor = clamp(device.videoZoomFactor, minZoom, maxZoom)

        currentExposure = ExposureParams(device: device)
    }

    static func fNumberLabel(_ f: Float) -> String {
        if abs(f.rounded() - f) < 0.05 {
            return String(format: "f/%.0f", f)
        }
        return String(format: "f/%.1f", f)
    }

    // MARK: - Zoom

    func setZoom(_ factor: CGFloat, ramped: Bool = false) {
        let target = clamp(factor, minZoom, maxZoom)
        Task { [weak self] in
            guard let self else { return }
            await session.withDevice { device -> Void in
                if ramped {
                    device.ramp(toVideoZoomFactor: target, withRate: 4)
                } else {
                    device.videoZoomFactor = target
                }
            }
            zoomFactor = target
        }
    }

    func zoomBy(_ delta: CGFloat) {
        setZoom(zoomFactor + delta)
    }

    // MARK: - Focus

    func focus(atNormalizedPoint point: CGPoint) {
        Task { [weak self] in
            guard let self else { return }
            await session.withDevice { device -> Void in
                guard device.isFocusPointOfInterestSupported else { return }
                device.focusPointOfInterest = point
                if device.isFocusModeSupported(.autoFocus) {
                    device.focusMode = .autoFocus
                }
                if device.isExposurePointOfInterestSupported {
                    device.exposurePointOfInterest = point
                    if device.isExposureModeSupported(.continuousAutoExposure) {
                        device.exposureMode = .continuousAutoExposure
                    }
                }
            }
            isAEAFLocked = false
        }
    }

    func setFocusLocked(_ locked: Bool) {
        Task { [weak self] in
            guard let self else { return }
            await session.withDevice { device -> Void in
                if locked {
                    if device.isFocusModeSupported(.locked) { device.focusMode = .locked }
                    if device.isExposureModeSupported(.locked) { device.exposureMode = .locked }
                } else {
                    if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
                    if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
                }
            }
            isAEAFLocked = locked
        }
    }

    // MARK: - Exposure

    func applyAutoExposure() {
        Task { [weak self] in
            guard let self else { return }
            await session.withDevice { device -> Void in
                // There is no `setContinuousAutoExposure()` method; continuous
                // exposure is reached by assigning the mode property.
                if device.isExposureModeSupported(.continuousAutoExposure) {
                    device.exposureMode = .continuousAutoExposure
                }
            }
            if let device = await session.withDevice({ $0 }) {
                currentExposure = ExposureParams(device: device)
                onExposureChanged?(currentExposure)
            }
        }
    }

    func applyManualExposure(duration: Double, iso: Float) async {
        guard let device = await session.withDevice({ $0 }) else { return }
        let activeLimits = ExposureClamper.limits(for: device)
        let accepted = await verifier.apply(duration: duration, iso: iso, to: device, limits: activeLimits)
        await MainActor.run {
            if let accepted {
                self.currentExposure = accepted
                self.onExposureChanged?(accepted)
            }
        }
    }

    func readExposure() async -> ExposureParams? {
        guard let device = await session.withDevice({ $0 }) else { return nil }
        let params = ExposureParams(device: device)
        currentExposure = params
        return params
    }

    /// Exposure compensation in stops, relative to the metered auto value.
    /// Used by the framing engine to bias exposure for the suggested crop.
    func applyEVCompensation(_ ev: Double, around anchor: ExposureParams) async {
        let factor = pow(2.0, ev)
        var iso = Float(Double(anchor.iso) * factor)
        var duration = anchor.duration / factor

        // Prefer raising ISO over lengthening the exposure before touching blur/sharpness.
        if iso > limits.maxISO {
            duration *= Double(limits.maxISO) / Double(max(iso, 1))
            iso = limits.maxISO
        }
        if duration > limits.maxDuration {
            iso = Float(Double(iso) * limits.maxDuration / duration)
            duration = limits.maxDuration
        }
        if iso < limits.minISO {
            duration *= Double(limits.minISO) / Double(max(iso, 1))
            iso = limits.minISO
        }

        await applyManualExposure(duration: clamp(duration, limits.minDuration, limits.maxDuration), iso: iso)
    }

    // MARK: - Torch

    func setTorch(_ on: Bool) {
        Task { [weak self] in
            guard let self else { return }
            // The session helper already holds the configuration lock — do not
            // lock again here, AVFoundation's lock is not reentrant.
            await session.withDevice { device -> Void in
                guard device.hasTorch, device.isTorchAvailable else { return }
                device.torchMode = on ? .on : .off
            }
            isTorchOn = on
        }
    }
}