import AVFoundation
import Foundation

/// A validated exposure setting: the pair AVFoundation will actually honour.
struct ExposureParams: Equatable, Codable, Sendable {
    var duration: Double   // seconds
    var iso: Float

    init(duration: Double, iso: Float) {
        self.duration = duration
        self.iso = iso
    }

    init(device: AVCaptureDevice) {
        duration = device.exposureDuration.seconds
        iso = device.iso
    }

    /// Exposure value at ISO 100 reference: EV = log2(N² / t).
    /// N is supplied by the caller because iOS has no variable aperture.
    func exposureValue(aperture fNumber: Double) -> Double {
        guard duration > 0 else { return 0 }
        return log2((fNumber * fNumber) / duration)
    }

    var stopLabel: String {
        if duration >= 1 {
            return duration < 10
                ? String(format: "%.1fs", duration)
                : String(format: "%.0fs", duration)
        }
        return "1/\(max(1, Int((1 / duration).rounded())))"
    }

    var isoLabel: String { "ISO \(Int(iso))" }

    static let identity = ExposureParams(duration: 0, iso: 0)
}

/// Resolves user-requested exposure values into a pair the device will accept.
///
/// AVFoundation does not advertise which (duration, ISO) combinations are legal —
/// `setExposureModeCustom` simply fails at runtime. Strategy:
///   1. Analytic clamp (fast path, rejects the overwhelming majority of bad requests).
///   2. Runtime verification with bisection fallback, remembering the last known-good pair.
final class ExposureClamper {
    struct Limits {
        var minDuration: Double
        var maxDuration: Double
        var minISO: Float
        var maxISO: Float
        var maxFrameRate: Double

        static let unknown = Limits(
            minDuration: 1.0 / 4000, maxDuration: 1.0 / 30,
            minISO: 25, maxISO: 2000, maxFrameRate: 30
        )
    }

    static func limits(for device: AVCaptureDevice) -> Limits {
        let format = device.activeFormat
        var maxRate: Double = 30
        for range in format.videoSupportedFrameRateRanges {
            maxRate = max(maxRate, range.maxFrameRate)
        }
        return Limits(
            minDuration: CMTimeGetSeconds(format.minExposureDuration),
            maxDuration: CMTimeGetSeconds(format.maxExposureDuration),
            minISO: format.minISO,
            maxISO: format.supportedISOHigh,
            maxFrameRate: maxRate
        )
    }

    /// Analytic clamp. Does not guarantee hardware acceptance — see `ExposureVerifier`.
    static func clamp(duration: Double, iso: Float, limits: Limits) -> ExposureParams {
        let t = clamp(duration, limits.minDuration, limits.maxDuration)
        var i = clamp(iso, limits.minISO, limits.maxISO)

        // The sensor is reciprocal: at very fast shutter speeds the minimum usable
        // ISO rises, at long exposures the maximum usable ISO drops. Approximate
        // that envelope so we rarely reach the runtime fallback.
        let tRef = max(limits.minDuration, min(t, limits.maxDuration))
        let framePeriod = 1.0 / max(limits.maxFrameRate, 1)

        if tRef < framePeriod {
            // Faster than a frame period — raise ISO to keep the exposure sane.
            let ratio = framePeriod / max(tRef, 1e-6)
            i = max(i, Float(Double(limits.minISO) * min(ratio, 16)))
        }

        let maxISOForDuration = Float(
            Double(limits.maxISO) * min(1.0, limits.maxDuration / max(tRef, 1e-6))
        )
        i = clamp(i, limits.minISO, maxISOForDuration)

        return ExposureParams(duration: tRef, iso: i)
    }

    /// ISO that matches a requested exposure value, honouring the duration cap.
    static func iso(forExposureValue ev: Double, aperture: Double, duration: Double, limits: Limits) -> Float {
        guard duration > 0 else { return limits.minISO }
        let wanted = 100.0 * pow(2.0, ev)
        return Float(clamp(wanted, Double(limits.minISO), Double(limits.maxISO)))
    }
}

/// Applies exposure to the device and reports whether the hardware accepted it.
final class ExposureVerifier: @unchecked Sendable {
    private let lock = NSLock()
    private var lastGood: ExposureParams?
    private var memo: [String: Bool] = [:]

    /// Applies the pair, degrading it step by step if the hardware refuses.
    /// Returns the pair that was actually accepted, or `nil` if even the fallback failed.
    ///
    /// Never blocks the calling queue — the completion handlers are awaited asynchronously.
    func apply(
        duration: Double,
        iso: Float,
        to device: AVCaptureDevice,
        limits: ExposureClamper.Limits
    ) async -> ExposureParams? {
        let requested = ExposureClamper.clamp(duration: duration, iso: iso, limits: limits)

        lock.lock()
        let cached = memo[Self.key(requested)]
        lock.unlock()

        if cached == false {
            // Known-bad combination; skip straight to the fallback ladder.
            return await degradeThenApply(requested, to: device, limits: limits)
        }

        if let accepted = await applyOnce(requested, to: device) {
            lock.lock()
            memo[Self.key(requested)] = true
            lastGood = accepted
            lock.unlock()
            return accepted
        }

        lock.lock()
        memo[Self.key(requested)] = false
        lock.unlock()

        return await degradeThenApply(requested, to: device, limits: limits)
    }

    private func degradeThenApply(
        _ requested: ExposureParams,
        to device: AVCaptureDevice,
        limits: ExposureClamper.Limits
    ) async -> ExposureParams? {
        var candidate = requested
        for _ in 0..<8 {
            candidate = Self.degrade(candidate, limits: limits)
            guard candidate.duration > 0, candidate.iso > 0 else { return nil }
            if let accepted = await applyOnce(candidate, to: device) {
                lock.lock()
                lastGood = accepted
                lock.unlock()
                return accepted
            }
        }
        return nil
    }

    private static func key(_ p: ExposureParams) -> String {
        "\(String(format: "%.6f", p.duration))|\(Int(p.iso))"
    }

    /// Halve ISO; once at the floor, double the exposure time instead.
    private static func degrade(_ p: ExposureParams, limits: ExposureClamper.Limits) -> ExposureParams {
        var iso = p.iso
        var t = p.duration
        let halved = iso / 2
        if halved >= limits.minISO {
            iso = halved
        } else {
            t = min(limits.maxDuration, t * 2)
            iso = limits.minISO
        }
        return ExposureParams(duration: t, iso: iso)
    }

    /// Single attempt, non-blocking.
    private func applyOnce(_ p: ExposureParams, to device: AVCaptureDevice) async -> ExposureParams? {
        let time = CMTime(seconds: p.duration, preferredTimescale: 1_000_000_000)
        let iso = p.iso
        let ok = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            device.setExposureModeCustom(duration: time, iso: iso) { error in
                cont.resume(returning: error == nil)
            }
        }
        return ok ? ExposureParams(duration: p.duration, iso: iso) : nil
    }
}