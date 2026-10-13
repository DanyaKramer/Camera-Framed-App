import AVFoundation
import Foundation
import UIKit

/// Owns the `AVCaptureSession` and its graph. All configuration runs on a private
/// serial queue; state is published back to the main actor explicitly.
final class CameraSessionController: NSObject, @unchecked Sendable {
    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "com.frameapp.camera.session", qos: .userInitiated)
    private let videoOutput = AVCaptureVideoDataOutput()
    private let photoOutput = AVCapturePhotoOutput()

    private(set) var videoDevice: AVCaptureDevice?
    private(set) var position: AVCaptureDevice.Position = .back
    private var currentRotation: CGFloat = 90
    private var isMirrored = false

    let frameStreamer = FrameStreamer()

    // MARK: - Lifecycle

    func start() {
        sessionQueue.async { [self] in
            guard !session.isRunning else { return }
            session.startRunning()
        }
    }

    func stop() {
        sessionQueue.async { [self] in
            guard session.isRunning else { return }
            session.stopRunning()
        }
    }

    var isRunning: Bool { session.isRunning }

    // MARK: - Configuration

    func configure(position desiredPosition: AVCaptureDevice.Position) async -> Result<AVCaptureDevice, CameraError> {
        await withCheckedContinuation { cont in
            sessionQueue.async { [self] in
                do {
                    let device = try Self.build(position: desiredPosition)
                    try Self.attach(device: device, to: session)
                    self.videoDevice = device
                    self.position = desiredPosition
                    self.isMirrored = desiredPosition == .front
                    session.commitConfiguration()
                    applyRotation(self.currentRotation)
                    cont.resume(returning: .success(device))
                } catch let error as CameraError {
                    cont.resume(returning: .failure(error))
                } catch {
                    cont.resume(returning: .failure(.configurationFailed(error.localizedDescription)))
                }
            }
        }
    }

    /// Prefers the widest built-in device so that the virtual-device stack exposes
    /// ultra-wide / wide / tele switching through `videoZoomFactor`.
    private static func build(position: AVCaptureDevice.Position) throws -> AVCaptureDevice {
        let preferred: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera,
            .builtInDualWideCamera,
            .builtInDualCamera,
            .builtInWideAngleCamera
        ]
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: preferred,
            mediaType: .video,
            position: position
        )
        // Prefer the wide-angle constituent of a multi-camera rig.
        let candidates = discovery.devices.sorted { lhs, rhs in
            rank(lhs.deviceType) < rank(rhs.deviceType)
        }
        if let device = candidates.first(where: { $0.deviceType == .builtInWideAngleCamera }) ?? candidates.first {
            return device
        }
        guard let fallback = AVCaptureDevice.default(for: .video) else {
            throw CameraError.noDevice
        }
        return fallback
    }

    private static func rank(_ type: AVCaptureDevice.DeviceType) -> Int {
        switch type {
        case .builtInTripleCamera: 0
        case .builtInDualWideCamera: 1
        case .builtInDualCamera: 2
        case .builtInWideAngleCamera: 3
        default: 4
        }
    }

    private static func attach(device: AVCaptureDevice, to session: AVCaptureSession) throws {
        session.beginConfiguration()

        session.sessionPreset = .photo

        // Replace any existing video input.
        for input in session.inputs where input.mediaType == .video {
            session.removeInput(input)
        }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw CameraError.configurationFailed("не удалось добавить вход камеры")
        }
        session.addInput(input)

        // Photo output — the full-resolution still capture path.
        if !session.outputs.contains(photoOutput) {
            guard session.canAddOutput(photoOutput) else {
                session.commitConfiguration()
                throw CameraError.configurationFailed("не удалось добавить выход фото")
            }
            session.addOutput(photoOutput)
            photoOutput.maxPhotoQualityPrioritization = .quality
        }

        // Video output — analysis frames only.
        if !session.outputs.contains(videoOutput) {
            guard session.canAddOutput(videoOutput) else {
                session.commitConfiguration()
                throw CameraError.configurationFailed("не удалось добавить выход видео")
            }
            videoOutput.alwaysDiscardsLateVideoFrames = true
            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            ]
            session.addOutput(videoOutput)
            videoOutput.setSampleBufferDelegate(
                frameStreamer,
                queue: DispatchQueue(label: "com.frameapp.camera.analysis", qos: .userInitiated)
            )
        }
    }

    // MARK: - Rotation / mirroring

    /// Keeps the analysis buffer and the preview layer in the same orientation.
    ///
    /// This is the single most important detail for the framing engine: because both
    /// connections share a rotation angle, normalized coordinates produced by the
    /// analyser can be used directly in preview layer space.
    func setOrientation(_ rotationAngle: CGFloat) {
        sessionQueue.async { [self] in
            currentRotation = rotationAngle
            applyRotation(rotationAngle)
        }
    }

    private func applyRotation(_ angle: CGFloat) {
        for output in [videoOutput as AVCaptureOutput, photoOutput as AVCaptureOutput] {
            guard let connection = output.connection(with: .video) else { continue }
            if connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = angle
            }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = isMirrored
            }
        }
    }

    // MARK: - Outputs access (session queue)

    func withDevice<T>(_ body: @escaping @Sendable (AVCaptureDevice) -> T) async -> T? {
        await withCheckedContinuation { cont in
            sessionQueue.async { [self] in
                guard let device = videoDevice else {
                    cont.resume(returning: nil)
                    return
                }
                var result: T?
                device.lockForConfiguration()
                result = body(device)
                device.unlockForConfiguration()
                cont.resume(returning: result)
            }
        }
    }

    /// Configuration body that needs an async device call while locked.
    func withDeviceAsync<T>(_ body: @escaping @Sendable (AVCaptureDevice) async -> T) async -> T? {
        let holder = DeviceBox()
        await withCheckedContinuation { cont in
            sessionQueue.async { [self] in
                guard let device = videoDevice else {
                    cont.resume(returning: ())
                    return
                }
                holder.device = device
                device.lockForConfiguration()
                cont.resume(returning: ())
            }
        }
        guard let device = holder.device else { return nil }
        let value = await body(device)
        await withCheckedContinuation { cont in
            sessionQueue.async {
                device.unlockForConfiguration()
                cont.resume(returning: ())
            }
        }
        return value
    }

    var photoOutputRef: AVCapturePhotoOutput { photoOutput }
}

/// Mutable box so a device reference can cross an isolation boundary safely.
private final class DeviceBox: @unchecked Sendable {
    var device: AVCaptureDevice?
}