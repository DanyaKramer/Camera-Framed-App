import AVFoundation
import Foundation
import Photos

enum CameraAuthorization {
    case notDetermined
    case authorized
    case denied
    case restricted

    init(_ status: AVAuthorizationStatus) {
        switch status {
        case .authorized: self = .authorized
        case .denied: self = .denied
        case .restricted: self = .restricted
        case .notDetermined: self = .notDetermined
        @unknown default: self = .notDetermined
        }
    }
}

enum CameraError: LocalizedError {
    case permissionDenied
    case noDevice
    case configurationFailed(String)
    case captureFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            "Нет доступа к камере. Разрешите его в Настройках."
        case .noDevice:
            "Камера не найдена."
        case .configurationFailed(let m):
            "Не удалось настроить камеру: \(m)"
        case .captureFailed(let m):
            "Ошибка съёмки: \(m)"
        }
    }
}

enum CameraPermissions {
    static var status: CameraAuthorization {
        CameraAuthorization(AVCaptureDevice.authorizationStatus(for: .video))
    }

    static func request() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    static func photoLibraryAddStatus() -> PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .addOnly)
    }

    static func requestPhotoLibraryAdd() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .addOnly)
    }
}