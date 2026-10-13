import AVFoundation
import Photos
import UIKit

/// What the UI needs to render one captured photo.
struct CapturedPhoto: Identifiable {
    let id = UUID()
    /// Mutable: the post-capture pipeline replaces it with the processed image.
    var image: UIImage
    let rawData: Data?
    let settings: ExposureParams
    let resolvedDuration: Double
    let resolvedISO: Float
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

/// Wraps `AVCapturePhotoOutput` with the manual-exposure path the UI needs.
///
/// The critical detail: device-level `setExposureModeCustom` only drives the
/// *preview*. The still is captured through `AVCapturePhotoSettings`, so the exact
/// (duration, ISO) pair is pushed there too, and the values the hardware actually
/// resolved are read back from `AVCaptureResolvedPhotoSettings` — with
/// `.quality` prioritization the system may override what was requested.
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

    var supportsDepth: Bool { !output.availableDepthDataFormats.isEmpty }

    func capture(
        exposure: ExposureParams?,
        wantsRAW: Bool,
        aspect: AspectRatio
    ) async throws -> CapturedPhoto {
        guard let settings = makeSettings(exposure: exposure, wantsRAW: wantsRAW) else {
            throw PhotoOutputError.settingsUnavailable
        }

        return try await withCheckedThrowingContinuation { cont in
            let proxy = CaptureContinuationBox(
                continuation: cont,
                service: self,
                wantsRAW: wantsRAW,
                aspect: aspect
            )
            output.capturePhoto(with: settings, delegate: proxy)
        }
    }

    private func makeSettings(exposure: ExposureParams?, wantsRAW: Bool) -> AVCapturePhotoSettings? {
        let settings: AVCapturePhotoSettings
        if wantsRAW, let rawType = output.availableRawPhotoPixelFormatTypes.first {
            settings = AVCapturePhotoSettings(rawPixelFormatType: rawType)
        } else {
            settings = AVCapturePhotoSettings()
        }

        settings.photoQualityPrioritization = .quality
        settings.maxPhotoDimensions = output.maxPhotoDimensions

        if let previewType = settings.availablePreviewPhotoPixelFormatTypes.first {
            settings.previewPhotoFormat = [
                kCVPixelBufferPixelFormatTypeKey as String: previewType
            ]
        }

        if supportsDepth {
            settings.isDepthDataDeliveryEnabled = true
        }

        // Push the exact exposure into the still capture itself.
        if let exposure, exposure.duration > 0, exposure.iso > 0 {
            let time = CMTime(seconds: exposure.duration, preferredTimescale: 1_000_000_000)
            settings.setCustomPhotoExposureMode(duration: time, iso: exposure.iso) { _, _ in
                // The values actually used arrive via AVCaptureResolvedPhotoSettings.
            }
        }

        return settings
    }

    fileprivate func fail(_ error: Error) {
        onCaptureFinished?(.failure(error))
    }

    fileprivate func report(progress: Double) {
        onProgress?(progress)
    }
}

/// `AVCapturePhotoOutput.capturePhoto` needs a long-lived delegate; this box keeps
/// the continuation alive for exactly one capture.
private final class CaptureContinuationBox: NSObject, AVCapturePhotoCaptureDelegate {
    private var continuation: CheckedContinuation<CapturedPhoto, Error>?
    private weak var service: PhotoCaptureService?
    private var wantsRAW = false
    private var aspect: AspectRatio = .landscape4x3
    private var finished = false

    init(
        continuation: CheckedContinuation<CapturedPhoto, Error>,
        service: PhotoCaptureService,
        wantsRAW: Bool,
        aspect: AspectRatio
    ) {
        self.continuation = continuation
        self.service = service
        self.wantsRAW = wantsRAW
        self.aspect = aspect
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
                self.service?.fail(CameraError.captureFailed(error.localizedDescription))
                self.resolve(.failure(error))
                return
            }

            guard let data = photo.fileDataRepresentation(), let image = UIImage(data: data) else {
                let error = PhotoOutputError.noPhotoData
                self.service?.fail(error)
                self.resolve(.failure(error))
                return
            }

            let resolved = photo.resolvedPhotoSettings
            let exposure = ExposureParams(
                duration: resolved.exposureDuration.seconds,
                iso: resolved.iso
            )

            let captured = CapturedPhoto(
                image: image,
                rawData: self.wantsRAW ? data : nil,
                settings: exposure,
                resolvedDuration: resolved.exposureDuration.seconds,
                resolvedISO: resolved.iso,
                metadata: photo.metadata,
                depthData: photo.depthData,
                aspect: self.aspect
            )

            self.service?.onCaptureFinished?(.success(captured))
            self.resolve(.success(captured))
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

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        willCapturePhotoFor resolvedSettings: AVCaptureResolvedPhotoSettings,
        proposedCaptureTimestamp: CMTime
    ) {
        Task { @MainActor [weak self] in
            self?.service?.report(progress: 0.15)
        }
    }
}