import AVFoundation
import Combine
import CoreImage
import Foundation
import Photos
import UIKit

/// App-level state machine: owns the camera stack, the framing engine and the
/// mode transitions (auto / manual / scan / guide).
@MainActor
@Observable
final class CameraController {
    enum Mode: String, CaseIterable, Identifiable {
        case auto, manual, scan, guide

        var id: String { rawValue }

        var title: String {
            switch self {
            case .auto: "Авто"
            case .manual: "Ручной"
            case .scan: "Скан"
            case .guide: "Наведение"
            }
        }

        var icon: String {
            switch self {
            case .auto: "a.circle"
            case .manual: "dial.medium"
            case .scan: "viewfinder"
            case .guide: "scope"
            }
        }
    }

    // MARK: - Dependencies

    let session = CameraSessionController()
    let device: CameraDeviceController
    let capture: PhotoCaptureService
    let settings = AppSettings()
    private let engine = FramingEngine()
    private let matcher = LiveMatcher()
    private let pipeline = ImagePipeline()

    // MARK: - Lifecycle state

    var authorization: CameraAuthorization = CameraPermissions.status
    var isSessionRunning = false
    var isConfigured = false
    var busyMessage: String?
    var errorMessage: String?
    var rotationAngle: CGFloat = 90

    /// Aspect (w/h) of the analysis buffer. Drives where the preview is letterboxed,
    /// so the mask, the grid and the analysis all agree on where the frame sits.
    private(set) var bufferAspect: CGFloat = 3.0 / 4.0

    /// 64-bin histogram for the manual-mode readout.
    private(set) var histogramBins: [Double] = Array(repeating: 0, count: 64)

    // MARK: - Mode state

    var mode: Mode = .auto {
        didSet { handleModeChange(from: oldValue) }
    }

    // Manual exposure
    var manualDuration: Double = 1.0 / 120
    var manualISO: Float = 200
    /// User-selected f-stop. Drives exposure compensation and bokeh.
    var selectedAperture: Double = 1.8
    var exposureFixed = false
    private var apertureBaselineISO: Float?

    // Framing
    var isScanning = false
    var pendingRecipe: FramingRecipe?
    var activeRecipe: FramingRecipe?
    var match = MatchResult.idle
    var matchStreak = 0
    var isAutoTriggered = false

    // Live guidance state, mirrored out of the matcher for the overlay.
    var guidancePhase: GuidancePhase = .idle
    /// Normalised to the visible frame — same space as every analysis coordinate.
    private(set) var liveSubjectBounds: CGRect?
    private(set) var liveSubjectLabel: String = ""

    // Capture
    var isCapturing = false
    var captureProgress: Double = 0
    var lastThumbnail: UIImage?
    var lastCaptured: CapturedPhoto?

    // Recipes library
    var savedRecipes: [FramingRecipe] = RecipeStore.shared.load()

    // Debug
    var showAnalysisOverlay = false
    var lastAnalysisScoreComponents: [String: Double] = [:]

    // MARK: - Init

    init() {
        device = CameraDeviceController(session: session)
        capture = PhotoCaptureService(session: session)

        capture.onProgress = { [weak self] p in
            self?.captureProgress = p
        }
        capture.onCaptureFinished = { [weak self] result in
            self?.handleCaptureResult(result)
        }

        device.onExposureChanged = { [weak self] params in
            guard let self, !self.exposureFixed else { return }
            self.manualISO = params.iso
            self.manualDuration = max(params.duration, 1.0 / 8000)
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(orientationChanged),
            name: UIDevice.orientationDidChangeNotification,
            object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Startup

    func start() async {
        guard authorization != .authorized else {
            await configureAndRun()
            return
        }

        let granted = await CameraPermissions.request()
        authorization = CameraPermissions.status
        guard granted else {
            errorMessage = CameraError.permissionDenied.localizedDescription
            return
        }
        await configureAndRun()
    }

    func configureAndRun() async {
        let result = await session.configure(position: .back)
        switch result {
        case .success(let device):
            self.device.adopt(device: device)
            isConfigured = true
            errorMessage = nil
            session.setOrientation(rotationAngle)
            session.start()
            isSessionRunning = true

            session.frameStreamer.onFrame = { frame in
                // The frame queue is not main-actor isolated — hop explicitly.
                Task { @MainActor [weak self] in
                    self?.trackFrameShape(frame)
                }
            }
            startLiveLoop()
        case .failure(let error):
            errorMessage = error.localizedDescription
        }
    }

    func stopSession() {
        session.stop()
        isSessionRunning = false
        liveLoopTask?.cancel()
        liveLoopTask = nil
    }

    func restartSession() async {
        stopSession()
        try? await Task.sleep(nanoseconds: 250_000_000)
        await configureAndRun()
    }

    @objc private func orientationChanged() {
        let angle: CGFloat
        switch UIDevice.current.orientation {
        case .portrait: angle = 90
        case .portraitUpsideDown: angle = 270
        case .landscapeLeft: angle = 0
        case .landscapeRight: angle = 180
        default: return
        }
        guard angle != rotationAngle else { return }
        rotationAngle = angle
        session.setOrientation(angle)
    }

    // MARK: - Mode transitions

    private func handleModeChange(from old: Mode) {
        switch mode {
        case .auto:
            // `activeRecipe` is deliberately kept: leaving guidance turns the scan
            // button into "rescan", which needs the recipe to still be there.
            pendingRecipe = nil
            resetGuidanceState()
            device.setTorch(false)
            device.applyAutoExposure()
        case .manual:
            // Manual shooting is a different activity — the stored framing is stale.
            pendingRecipe = nil
            activeRecipe = nil
            resetGuidanceState()
            Task { await syncManualExposure() }
        case .scan:
            pendingRecipe = nil
            resetGuidanceState()
        case .guide:
            break
        }
    }

    /// Drops the stored framing entirely — used when the capture aspect changes
    /// and the recipe no longer describes anything meaningful.
    func clearRecipe() {
        activeRecipe = nil
        pendingRecipe = nil
        resetGuidanceState()
        mode = .auto
    }

    private func resetGuidanceState() {
        match = .idle
        matchStreak = 0
        guidancePhase = .idle
        liveSubjectBounds = nil
        liveSubjectLabel = ""
    }

    // MARK: - Scan

    func runScan() async {
        guard !isScanning else { return }
        isScanning = true
        busyMessage = "Анализирую кадр…"
        defer {
            isScanning = false
            busyMessage = nil
        }

        guard let frame = session.frameStreamer.latestFrame else {
            errorMessage = "Нет кадра от камеры."
            return
        }

        let aspect = settings.aspect
        let analysis = await engine.scan(
            frame: frame,
            aspect: aspect,
            zoom: device.zoomFactor,
            minZoom: device.minZoom,
            maxZoom: device.maxZoom
        )

        guard let analysis else {
            errorMessage = "Не удалось проанализировать кадр."
            return
        }

        lastAnalysisScoreComponents = analysis.scoreComponents

        // The crop was found inside the *currently visible* area; re-express it in
        // zoom-1 frame coordinates, then solve for zoom + post-crop.
        let cropInZoomOne = FramingSolver.toZoomOneFrame(
            crop: analysis.crop,
            currentZoom: device.zoomFactor
        )
        let solution = FramingSolver.solve(
            cropInZoomOneFrame: cropInZoomOne,
            currentZoom: device.zoomFactor,
            limits: device.minZoom...device.maxZoom
        )

        let recipe = FramingRecipe(
            zoom: solution.zoom,
            photoCrop: solution.photoCrop,
            aspect: aspect,
            evAdjustment: analysis.evAdjustment,
            rollDegrees: analysis.rollDegrees,
            confidence: analysis.subject.isEmpty ? 0.5 * analysis.score : analysis.subject.confidence * analysis.score,
            subjectKind: analysis.subject.kind.displayName,
            subjectBounds: analysis.subjectBounds,
            meanLuminance: analysis.meanLuminance,
            clippedFraction: analysis.clippedFraction
        )
        var recipeWithThumb = recipe
        recipeWithThumb.thumbnail = makeThumbnail(frame.pixelBuffer, crop: analysis.crop)

        pendingRecipe = recipeWithThumb
        mode = .scan
    }

    func applyPendingRecipe() async {
        guard let recipe = pendingRecipe else { return }
        activeRecipe = recipe

        device.setZoom(recipe.zoom, ramped: true)

        if abs(recipe.evAdjustment) > 0.05 {
            if let anchor = await device.readExposure() {
                await device.applyEVCompensation(recipe.evAdjustment, around: anchor)
            }
        }

        matchStreak = 0
        mode = .guide
        startLiveLoop()
    }

    func discardPendingRecipe() {
        pendingRecipe = nil
        if mode == .scan { mode = .auto }
    }

    func saveRecipe(_ recipe: FramingRecipe) {
        savedRecipes.insert(recipe, at: 0)
        RecipeStore.shared.save(savedRecipes)
    }

    func useRecipe(_ recipe: FramingRecipe) {
        activeRecipe = recipe
        pendingRecipe = nil
        device.setZoom(recipe.zoom, ramped: true)
        mode = .guide
        startLiveLoop()
    }

    func deleteRecipes(at offsets: IndexSet) {
        savedRecipes.remove(atOffsets: offsets)
        RecipeStore.shared.save(savedRecipes)
    }

    // MARK: - Live matching loop

    private var liveLoopTask: Task<Void, Never>?

    private func startLiveLoop() {
        liveLoopTask?.cancel()
        liveLoopTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                try? await Task.sleep(nanoseconds: 110_000_000) // ~9 fps
            }
        }
    }

    private func tick() async {
        guard let recipe = activeRecipe, mode == .guide else { return }
        guard session.frameStreamer.beginAnalysis() else { return }
        defer { session.frameStreamer.endAnalysis() }

        guard let frame = session.frameStreamer.latestFrame else { return }

        let analysis = await engine.analyzeLive(
            frame: frame,
            aspect: recipe.aspect,
            zoom: device.zoomFactor
        )
        guard let analysis else { return }

        let result = matcher.match(
            live: analysis,
            target: recipe,
            threshold: settings.matchThreshold
        )

        // Any manual gesture hands control back to the user for a few seconds.
        let isOverridden = manualOverrideUntil.map { Date() < $0 } ?? false

        if !isOverridden {
            if settings.autoZoom, abs(result.zoomStops) > 0.02 {
                let next = CGFloat(Double(device.zoomFactor) * pow(2.0, result.zoomStops * 0.35))
                device.setZoom(next)
            }
            if settings.autoExposure, abs(result.evDelta) > 0.08,
               let anchor = await device.readExposure() {
                await device.applyEVCompensation(result.evDelta * 0.5, around: anchor)
            }
        }

        await MainActor.run {
            self.match = result
            self.guidancePhase = result.isAligned ? .aligned : .guiding
            self.liveSubjectBounds = analysis.subjectBounds
            self.liveSubjectLabel = analysis.subject.kind.displayName

            if result.isAligned {
                self.matchStreak += 1
            } else {
                self.matchStreak = 0
            }

            if result.isAligned,
               self.matchStreak >= matcher.config.alignedStreakRequired,
               settings.autoCapture,
               !self.isCapturing,
               !self.isAutoTriggered {
                self.isAutoTriggered = true
                self.triggerAutoCapture()
            }
        }
    }

    /// Leaves guidance mode. The recipe is kept so the scan button turns into
    /// "rescan" and the user can walk back onto the same framing.
    func exitGuidance() {
        match = .idle
        matchStreak = 0
        guidancePhase = .idle
        liveSubjectBounds = nil
        liveSubjectLabel = ""
        mode = .auto
    }

    /// Re-enters guidance for the recipe that is already stored.
    func reenterGuidance() {
        guard activeRecipe != nil else { return }
        device.setZoom(activeRecipe?.zoom ?? device.zoomFactor, ramped: true)
        matchStreak = 0
        mode = .guide
        startLiveLoop()
    }

    /// Set by gestures so the camera stops fighting the user.
    var manualOverrideUntil: Date?

    func noteUserInteraction() {
        manualOverrideUntil = Date().addingTimeInterval(4)
    }

    private func triggerAutoCapture() {
        let generator = UIImpactFeedbackGenerator(style: .medium)
        generator.prepare()
        generator.impactOccurred()
        Task { await capturePhoto() }
    }

    // MARK: - Focus

    /// Weak reference to the preview layer, used to convert a touch into the
    /// capture device's coordinate space. Without this conversion the focus point
    /// lands off-target as soon as there is letterboxing or a rotation.
    private weak var previewLayer: AVCaptureVideoPreviewLayer?

    func attachPreviewLayer(_ layer: AVCaptureVideoPreviewLayer?) {
        previewLayer = layer
    }

    /// `point` is in preview layer coordinates.
    func focus(atLayerPoint point: CGPoint) {
        let devicePoint: CGPoint
        if let layer = previewLayer {
            devicePoint = layer.captureDevicePointConverted(fromLayerPoint: point)
        } else {
            // Fallback: assume the tap already is in device space.
            devicePoint = point
        }
        device.focus(atNormalizedPoint: devicePoint)
    }

    // MARK: - Manual exposure

    func syncManualExposure() async {
        guard mode == .manual else { return }

        if !exposureFixed {
            if let params = await device.readExposure() {
                manualISO = params.iso
                manualDuration = clamp(params.duration, device.limits.minDuration, device.limits.maxDuration)
            }
        }

        let apertureCompensation = apertureCompensationEV
        await device.applyManualExposure(
            duration: manualDuration,
            iso: Float(Double(manualISO) / pow(2.0, apertureCompensation))
        )
    }

    /// Stopping the simulated aperture down costs light, so the exposure has to
    /// come up to compensate — exactly as on a real interchangeable-lens body.
    var apertureCompensationEV: Double {
        let ratio = selectedAperture / max(device.realAperture, 0.1)
        return 2.0 * log2(max(ratio, 0.01))
    }

    func setAperture(_ value: Double) {
        selectedAperture = value
        guard mode == .manual else { return }
        Task { await syncManualExposure() }
    }

    func setShutter(_ seconds: Double) {
        exposureFixed = true
        manualDuration = clamp(seconds, device.limits.minDuration, device.limits.maxDuration)
        Task { await syncManualExposure() }
    }

    func setISO(_ iso: Float) {
        exposureFixed = true
        manualISO = clamp(iso, device.limits.minISO, device.limits.maxISO)
        Task { await syncManualExposure() }
    }

    /// The exposure triangle: given an exposure value, suggest the missing third value.
    func suggestISO(forDuration seconds: Double) -> Float {
        let ev = manualDuration > 0 ? log2(selectedAperture * selectedAperture / max(seconds, 1e-6)) : 0
        return Float(clamp(100.0 * pow(2.0, ev), Double(device.limits.minISO), Double(device.limits.maxISO)))
    }

    func suggestShutter(forISO iso: Float) -> Double {
        guard iso > 0 else { return manualDuration }
        let ev = log2(Double(iso) / 100.0)
        let t = (selectedAperture * selectedAperture) / pow(2.0, ev)
        return clamp(t, device.limits.minDuration, device.limits.maxDuration)
    }

    var shutterSteps: [Double] {
        // 1/8000 … 1/4 in 1/3-stop increments, then slower.
        var steps: [Double] = []
        var t = 1.0 / 8000.0
        while t < 0.26 {
            steps.append(t)
            t *= pow(2.0, 1.0 / 3.0)
        }
        steps.append(contentsOf: [0.3, 0.4, 0.5, 0.7, 1.0, 1.5, 2.0, 4.0])
        return steps.filter { $0 >= device.limits.minDuration * 0.95 && $0 <= device.limits.maxDuration * 1.05 }
    }

    var isoSteps: [Float] {
        var steps: [Float] = []
        var iso: Float = max(device.limits.minISO, 25)
        while iso <= device.limits.maxISO * 1.05 {
            steps.append(iso)
            iso *= 1.26 // ~1/3 stop
        }
        return steps
    }

    var apertureSteps: [Double] {
        [1.4, 1.8, 2.2, 2.8, 4.0, 5.6, 8.0, 11.0, 16.0]
    }

    // MARK: - Capture

    func capturePhoto() async {
        guard !isCapturing, isConfigured else { return }
        isCapturing = true
        captureProgress = 0
        isAutoTriggered = false

        let aspect = settings.aspect
        let exposure: ExposureParams? = (mode == .manual)
            ? ExposureParams(duration: manualDuration, iso: manualISO)
            : nil

        do {
            _ = try await capture.capture(
                exposure: exposure,
                wantsRAW: settings.saveRAW,
                aspect: aspect
            )
        } catch {
            errorMessage = error.localizedDescription
            isCapturing = false
        }
    }

    private func handleCaptureResult(_ result: Result<CapturedPhoto, Error>) {
        switch result {
        case .failure(let error):
            errorMessage = error.localizedDescription
            isCapturing = false

        case .success(let captured):
            isCapturing = false
            captureProgress = 1

            Task {
                busyMessage = settings.depthOfFieldEnabled ? "Обрабатываю…" : nil
                let finished = await pipeline.process(
                    captured,
                    aspect: settings.aspect,
                    depthOfField: settings.depthOfFieldEnabled,
                    aperture: selectedAperture
                )
                busyMessage = nil
                lastCaptured = finished
                lastThumbnail = finished.image
                await save(finished)
            }
        }
    }

    private func save(_ photo: CapturedPhoto) async {
        let status = CameraPermissions.photoLibraryAddStatus()
        if status == .notDetermined {
            _ = await CameraPermissions.requestPhotoLibraryAdd()
        }

        guard CameraPermissions.photoLibraryAddStatus() == .authorized
                || CameraPermissions.photoLibraryAddStatus() == .limited else {
            return
        }

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                if let data = photo.image.jpegData(compressionQuality: 0.96) {
                    // `options:` has no default value in Swift, pass nil explicitly.
                    request.addResource(with: .photo, data: data, options: nil)
                }
            } completionHandler { _, _ in
                cont.resume()
            }
        }
    }

    // MARK: - Helpers

    /// Lightweight per-frame bookkeeping: buffer geometry and the histogram.
    private func trackFrameShape(_ frame: FrameStreamer.Frame) {
        let w = CGFloat(CVPixelBufferGetWidth(frame.pixelBuffer))
        let h = CGFloat(CVPixelBufferGetHeight(frame.pixelBuffer))
        guard w > 0, h > 0 else { return }

        // Throttle: the histogram is only useful at a few Hz.
        guard frame.sequence % 12 == 0 else { return }

        Task { @MainActor [weak self] in
            guard let self else { return }
            self.bufferAspect = w / h
            if let prepared = FramingEngine.prepare(frame.pixelBuffer, longEdge: 96) {
                self.histogramBins = Self.histogram(prepared.luminance)
            }
        }
    }

    private static func histogram(_ luma: [Float]) -> [Double] {
        guard !luma.isEmpty else { return Array(repeating: 0, count: 64) }
        var bins = [Double](repeating: 0, count: 64)
        for value in luma {
            let bin = min(63, max(0, Int(Double(value) * 64)))
            bins[bin] += 1
        }
        return bins
    }

    private func makeThumbnail(_ buffer: CVPixelBuffer, crop: CGRect) -> Data? {
        guard let image = Self.croppedImage(buffer: buffer, crop: crop) else { return nil }
        let small = image.preparingThumbnail(of: CGSize(width: 240, height: 240)) ?? image
        return small.jpegData(compressionQuality: 0.6)
    }

    private static func croppedImage(buffer: CVPixelBuffer, crop: CGRect) -> UIImage? {
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let rect = crop.clampedToBounds(CGRect(x: 0, y: 0, width: 1, height: 1))
        let cgRect = CGRect(
            x: rect.minX * CGFloat(width),
            y: rect.minY * CGFloat(height),
            width: rect.width * CGFloat(width),
            height: rect.height * CGFloat(height)
        )
        // `CIImage(cvPixelBuffer:)` is failable only in older SDKs; on iOS 17 it
// returns a non-optional value.
        let ciImage = CIImage(cvPixelBuffer: buffer)
        let cropped = ciImage.cropped(to: cgRect)
        let context = CIContext(options: nil)
        guard let cgImage = context.createCGImage(cropped, from: cropped.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}