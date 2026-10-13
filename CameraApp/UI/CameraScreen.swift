import SwiftUI
import UIKit

struct CameraScreen: View {
    @Environment(CameraController.self) private var controller

    @State private var showSettings = false
    @State private var showRecipes = false

    var body: some View {
        ZStack {
            stage
                .ignoresSafeArea()

            VStack(spacing: 0) {
                TopBar(
                    controller: controller,
                    onOpenSettings: { showSettings = true },
                    onOpenRecipes: { showRecipes = true },
                    onExitGuidance: { controller.exitGuidance() },
                    onScan: { Task { await controller.runScan() } }
                )
                .padding(.top, 6)

                Spacer(minLength: 0)

                if controller.mode == .manual {
                    ManualControlsPanel(controller: controller)
                        .padding(.bottom, 4)
                }

                instruction

                ZoomControl(
                    minZoom: controller.device.minZoom,
                    maxZoom: controller.device.maxZoom,
                    zoom: controller.device.zoomFactor,
                    isLocked: controller.mode == .guide,
                    onChange: {
                        controller.noteUserInteraction()
                        controller.device.setZoom($0)
                    },
                    onInteraction: { controller.noteUserInteraction() }
                )
                .padding(.vertical, 10)

                shutterRow
                    .padding(.bottom, 18)
            }

            if controller.mode == .scan, let recipe = controller.pendingRecipe {
                ScanReviewView(
                    recipe: recipe,
                    onApply: { Task { await controller.applyPendingRecipe() } },
                    onRescan: { Task { await controller.runScan() } },
                    onSave: {
                        controller.saveRecipe(recipe)
                        controller.pendingRecipe = nil
                        controller.mode = .auto
                    },
                    onCancel: { controller.discardPendingRecipe() }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            stateOverlay
        }
        .animation(.snappy(duration: 0.25), value: controller.mode)
        .animation(.snappy(duration: 0.2), value: controller.guidancePhase)
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environment(controller)
        }
        .sheet(isPresented: $showRecipes) {
            RecipeGalleryView(controller: controller)
                .environment(controller)
        }
        .alert(
            "Ошибка",
            isPresented: Binding(
                get: { controller.errorMessage != nil },
                set: { if !$0 { controller.errorMessage = nil } }
            ),
            actions: { Button("Ок") { controller.errorMessage = nil } },
            message: { Text(controller.errorMessage ?? "") }
        )
    }

    // MARK: - Stage

    private var stage: some View {
        CaptureStage(
            session: controller.session.session,
            bufferAspect: controller.bufferAspect,
            aspect: controller.settings.aspect,
            gridStyle: controller.settings.gridStyle,
            gridOpacity: controller.settings.gridOpacity,
            rollDegrees: controller.mode == .guide
                ? controller.activeRecipe?.rollDegrees ?? 0
                : controller.match.rollDelta,
            showLevel: controller.settings.showLevel,
            onTapAtLayerPoint: { point in
                guard controller.mode != .guide else { return }
                controller.noteUserInteraction()
                controller.focus(atLayerPoint: point)
            },
            onPreviewLayerReady: { layer in
                controller.attachPreviewLayer(layer)
            }
        ) { geometry in
            if controller.mode == .guide, controller.activeRecipe != nil {
                GuidanceOverlay(
                    geometry: geometry,
                    match: controller.match,
                    phase: controller.guidancePhase,
                    streak: controller.matchStreak,
                    requiredStreak: 3,
                    subjectBounds: controller.liveSubjectBounds,
                    subjectLabel: controller.liveSubjectLabel.isEmpty
                        ? "объект"
                        : controller.liveSubjectLabel
                )
            }
        }
    }

    // MARK: - Instruction

    @ViewBuilder
    private var instruction: some View {
        if controller.mode == .guide {
            InstructionLine(
                text: controller.match.primaryInstruction,
                tint: CameraTheme.tint(for: controller.guidancePhase)
            )
            .padding(.bottom, 8)
        } else if controller.busyMessage != nil {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(controller.busyMessage ?? "")
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(.white)
            .padding(.bottom, 8)
        } else {
            HStack(spacing: 6) {
                Image(systemName: "sparkles")
                    .font(.system(size: 12, weight: .semibold))
                Text("Нажмите, чтобы найти удачный кадр")
                    .font(.system(size: 13, weight: .medium))
            }
            .foregroundStyle(.white.opacity(0.45))
            .padding(.bottom, 8)
        }
    }

    // MARK: - Shutter row

    private var shutterRow: some View {
        HStack(alignment: .center) {
            thumbnailButton
                .frame(width: 54)

            Spacer()

            ShutterButton(
                isCapturing: controller.isCapturing,
                progress: controller.captureProgress
            ) {
                Task { await controller.capturePhoto() }
            }

            Spacer()

            ScanButton(
                state: scanState,
                isBusy: controller.isScanning,
                action: handleScanAction
            )
            .frame(width: 54)
        }
        .padding(.horizontal, 26)
    }

    private var scanState: ScanButton.State {
        if controller.mode == .guide { return .guiding }
        if controller.activeRecipe != nil { return .scanned }
        return .idle
    }

    private func handleScanAction() {
        switch scanState {
        case .idle:
            Task { await controller.runScan() }
        case .scanned:
            controller.reenterGuidance()
        case .guiding:
            controller.exitGuidance()
        }
    }

    private var thumbnailButton: some View {
        Button {
            showRecipes = true
        } label: {
            Group {
                if let image = controller.lastThumbnail {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 18))
                        .foregroundStyle(.white.opacity(0.4))
                }
            }
            .frame(width: 48, height: 48)
            .background(
                RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.08))
            )
            .clipShape(RoundedRectangle(cornerRadius: 9))
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5)
            )
        }
    }

    // MARK: - States

    @ViewBuilder
    private var stateOverlay: some View {
        switch controller.authorization {
        case .denied, .restricted:
            MessageOverlay(
                icon: "camera.fill",
                title: "Нет доступа к камере",
                message: "Разрешите доступ в Настройках, чтобы снимать фото.",
                actionTitle: "Открыть Настройки",
                action: {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
            )
        case .notDetermined:
            MessageOverlay(
                icon: "camera",
                title: "Готовим камеру",
                message: "Разрешите доступ к камере при запросе."
            )
        case .authorized:
            Color.clear
        }
    }
}