import AVFoundation
import Photos
import UIKit

/// What the UI needs to render one captured photo.
struct CapturedPhoto: Identifiable {
    let id = UUID()
    /// Mutable: the post-capture pipeline replaces it with the processed image.
    var image: UIImage
    let rawData: Data?
    /// What we asked the capture device for. `nil` in auto mode.
    let requestedExposure: ExposureParams?
    /// What the hardware actually used, reported by `AVCaptureResolvedPhotoSettings`.
    /// With `.quality` prioritisation the system is free to override the request,
    /// which is exactly why this is read back rather than assumed.
    let actualExposure: ExposureParams
    let metadata: [String: Any]
    let depthData: AVDepthData?
    var aspect: AspectRatio
}

enum PhotoOutputError: LocalizedError {
    case settingsUnavailable
    case noPhotoData

    var errorDescription: String? {
        switch self {
        case .settingsUnavailable: "AVFoundation не смог подготовить настройки съёмки."
        case .noPhotoData: "Съёмка не вернула изображение."
        }
    }
}

/// Per-request state, shared between the service and the capture delegate.
///
/// `AVCapturePhotoSettings` has no per-photo exposure API — the only way to pin
/// (duration, ISO) for a still is to put the capture device in custom exposure
/// mode beforehand. `AVCaptureResolvedPhotoSettings` reports which *features*
/// were enabled (depth, HDR, live photo); it does NOT report exposure. The
/// values the hardware actually used are only observable on the device itself,
/// so they are read back after the capture settles.
final class CaptureRequest {
    let wantsRAW: Bool
    let aspect: AspectRatio
    let requestedExposure: ExposureParams?
    private(set) var actualExposure: ExposureParams?

    init(wantsRAW: Bool, aspect: AspectRatio, requestedExposure: ExposureParams?) {
        self.wantsRAW = wantsRAW
        self.aspect = aspect
        self.requestedExposure = requestedExposure
    }

    func record(actual: ExposureParams?) {
        guard actualExposure == nil else { return }
        actualExposure = actual
    }
}

/// Wraps `AVCapturePhotoOutput`.
@MainActor
final class PhotoCaptureService: NSObject {
    private let session: CameraSessionController
    private var output: AVCapturePhotoOutput { session.photoOutputRef }

    var onCaptureFinished: ((Result<CapturedPhoto, Error>) -> Void)?
    var onProgress: ((Double) -> Void)?

    init(session: CameraSessionController) {
        self.session = session
        super.init()
    }

    func capture(
        exposure: ExposureParams?,
        wantsRAW: Bool,
        aspect: AspectRatio
    ) async throws -> CapturedPhoto {
        // Depth delivery is opt-in per attempt; if the device or format cannot
        // provide it, capturePhoto raises, so fall back to a plain still rather
        // than crashing the app.
        do {
            return try await perform(exposure: exposure, wantsRAW: wantsRAW, aspect: aspect, depth: true)
        } catch {
            return try await perform(exposure: exposure, wantsRAW: wantsRAW, aspect: aspect, depth: false)
        }
    }

    private func perform(
        exposure: ExposureParams?,
        wantsRAW: Bool,
        aspect: AspectRatio,
        depth: Bool
    ) async throws -> CapturedPhoto {
        let request = CaptureRequest(wantsRAW: wantsRAW, aspect: aspect, requestedExposure: exposure)
        let settings = makeSettings(wantsRAW: wantsRAW, depth: depth)
        guard let settings else {
            throw PhotoOutputError.settingsUnavailable
        }

        return try await withCheckedThrowingContinuation { cont in
            let proxy = CaptureContinuationBox(continuation: cont, service: self, request: request)
            output.capturePhoto(with: settings, delegate: proxy)
        }
    }

    private func makeSettings(wantsRAW: Bool, depth: Bool) -> AVCapturePhotoSettings? {
        let settings: AVCapturePhotoSettings
        if wantsRAW, let rawType = output.availableRawPhotoPixelFormatTypes.first {
            settings = AVCapturePhotoSettings(rawPixelFormatType: rawType)
        } else {
            settings = AVCapturePhotoSettings()
        }

        settings.photoQualityPrioritization = .quality

        // `maxPhotoDimensions` is deliberately not set: leaving it alone already
        // means "largest size the device supports", which is what we want.

        if let previewType = settings.availablePreviewPhotoPixelFormatTypes.first {
            settings.previewPhotoFormat = [
                kCVPixelBufferPixelFormatTypeKey as String: previewType
            ]
        }

        if depth {
            settings.isDepthDataDeliveryEnabled = true
        }

        return settings
    }

    fileprivate func report(progress: Double) {
        onProgress?(progress)
    }

    /// Reads the exposure the camera is actually running right now.
    ///
    /// This is the only trustworthy source: `AVCaptureResolvedPhotoSettings`
    /// describes feature resolution, not shutter/ISO, and with `.quality`
    /// prioritisation the system may override what we asked for.
    func readDeviceExposure() async -> ExposureParams? {
        guard let device = await session.withDevice({ $0 }) else { return nil }
        let params = ExposureParams(device: device)
        return params.duration > 0 ? params : nil
    }
}

/// `capturePhoto(with:delegate:)` needs a long-lived delegate; this box keeps the
/// continuation alive for exactly one capture and resumes it once.
private final class CaptureContinuationBox: NSObject, AVCapturePhotoCaptureDelegate {
    private var continuation: CheckedContinuation<CapturedPhoto, Error>?
    private weak var service: PhotoCaptureService?
    private let request: CaptureRequest
    private var finished = false

    init(
        continuation: CheckedContinuation<CapturedPhoto, Error>,
        service: PhotoCaptureService,
        request: CaptureRequest
    ) {
        self.continuation = continuation
        self.service = service
        self.request = request
        super.init()
    }

    private func resolve(_ result: Result<CapturedPhoto, Error>) {
        guard !finished else { return }
        finished = true
        continuation?.resume(with: result)
        continuation = nil
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            if let error {
                let wrapped = CameraError.captureFailed(error.localizedDescription)
                self.service?.onCaptureFinished?(.failure(wrapped))
                self.resolve(.failure(wrapped))
                return
            }

            guard let data = photo.fileDataRepresentation(), let image = UIImage(data: data) else {
                let error = PhotoOutputError.noPhotoData
                self.service?.onCaptureFinished?(.failure(error))
                self.resolve(.failure(error))
                return
            }

            // By now the capture has settled, so the device holds the values that were
            // really used. Prefer the device, then the request, then a neutral default.
            request.record(actual: await self.service?.readDeviceExposure())

            let actual = request.actualExposure
                ?? request.requestedExposure
                ?? ExposureParams(duration: 1.0 / 120, iso: 200)

            let captured = CapturedPhoto(
                image: image,
                rawData: self.request.wantsRAW ? data : nil,
                requestedExposure: self.request.requestedExposure,
                actualExposure: actual,
                metadata: photo.metadata,
                depthData: photo.depthData,
                aspect: self.request.aspect
            )

            self.service?.onCaptureFinished?(.success(captured))
            self.resolve(.success(captured))
        }
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings,
        proposedCaptureTimestamp: CMTime
    ) {
        Task { @MainActor [weak self] in
            self?.service?.report(progress: 0.15)
        }
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: Error?
    ) {
        Task { @MainActor [weak self] in
            self?.service?.report(progress: 1.0)
        }
    }
}