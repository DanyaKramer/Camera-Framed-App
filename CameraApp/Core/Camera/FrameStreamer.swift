import AVFoundation
import CoreVideo
import Foundation

/// Holds the newest video frame and hands it to a single consumer.
///
/// `alwaysDiscardsLateVideoFrames` plus this latest-only slot is what keeps the
/// analysis pipeline from building a backlog: if analysis is slow, old frames are
/// dropped rather than queued.
final class FrameStreamer: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    struct Frame {
        let pixelBuffer: CVPixelBuffer
        let timestamp: CMTime
        let sequence: UInt64
    }

    private let lock = NSLock()
    private var latest: Frame?
    private var sequence: UInt64 = 0

    /// Frames whose analysis is in flight. Used by the engine to avoid re-entry.
    private var analysisInFlight = false

    var onFrame: (@Sendable (Frame) -> Void)?

    /// Mark analysis as started; returns false if an analysis is already running.
    func beginAnalysis() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !analysisInFlight else { return false }
        analysisInFlight = true
        return true
    }

    func endAnalysis() {
        lock.lock()
        analysisInFlight = false
        lock.unlock()
    }

    var latestFrame: Frame? {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        lock.lock()
        sequence &+= 1
        let frame = Frame(
            pixelBuffer: pixelBuffer,
            timestamp: CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
            sequence: sequence
        )
        latest = frame
        let handler = onFrame
        lock.unlock()

        handler?(frame)
    }
}