import SwiftUI
import UIKit

// MARK: - Shutter

struct ShutterButton: View {
    let isCapturing: Bool
    let progress: Double
    let action: () -> Void

    @State private var pressed = false

    var body: some View {
        ZStack {
            Circle()
                .fill(.white)
                .frame(width: 74, height: 74)
                .scaleEffect(pressed ? 0.92 : 1)
                .animation(.spring(response: 0.2, dampingFraction: 0.6), value: pressed)

            Circle()
                .strokeBorder(.white, lineWidth: 3)
                .frame(width: 82, height: 82)

            if isCapturing {
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(CameraTheme.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .frame(width: 76, height: 76)
                    .rotationEffect(.degrees(-90))
            }
        }
        .contentShape(Circle())
        .onTapGesture {
            guard !isCapturing else { return }
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            action()
        }
        .onLongPressGesture(minimumDuration: 0, maximumDistance: 40, pressing: { pressing in
            withAnimation { pressed = pressing }
        }, perform: {})
        .disabled(isCapturing)
    }
}

// MARK: - Zoom

struct ZoomControl: View {
    let minZoom: CGFloat
    let maxZoom: CGFloat
    let zoom: CGFloat
    let isLocked: Bool
    let onChange: (CGFloat) -> Void
    let onInteraction: () -> Void

    /// Presets plus whatever the auto-framing settled on, so the pill reflects
    /// the real value rather than going blank.
    private var pills: [CGFloat] {
        var values: [CGFloat] = [0.5, 1, 2, 5].filter {
            $0 >= minZoom - 0.01 && $0 <= maxZoom + 0.01
        }
        let inRange = zoom >= minZoom - 0.01 && zoom <= maxZoom + 0.01
        if inRange, zoom > 0.01, !values.contains(where: { abs($0 - zoom) < 0.05 }) {
            values.append((zoom * 10).rounded() / 10)
        }
        return values.sorted()
    }

    var body: some View {
        HStack(spacing: 12) {
            ForEach(pills, id: \.self) { value in
                let isActive = abs(zoom - value) < 0.05
                Button {
                    onInteraction()
                    onChange(value)
                } label: {
                    Text(label(for: value))
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(isActive ? CameraTheme.accent : .white)
                        .frame(width: 54, height: 54)
                        .background(
                            Circle().fill(
                                isActive ? CameraTheme.accent.opacity(0.16) : Color.black.opacity(0.55)
                            )
                        )
                }
                .disabled(isLocked)
            }
        }
        .animation(.snappy(duration: 0.2), value: zoom)
    }

    private func label(for value: CGFloat) -> String {
        value < 1 ? String(format: "%.1fx", value) : "\(Int(value.rounded()))x"
    }
}

// MARK: - Aspect menu (top left)

struct AspectMenu: View {
    @Binding var aspect: AspectRatio

    var body: some View {
        Menu {
            ForEach(AspectRatio.allCases) { option in
                Button {
                    aspect = option
                } label: {
                    Label(option.displayName, systemImage: option.icon)
                }
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: aspect.icon)
                    .font(.system(size: 17, weight: .regular))
                Text(aspect.displayName)
                    .font(.system(size: 16, weight: .semibold, design: .rounded))
                Image(systemName: "chevron.down")
                    .font(.system(size: 11, weight: .bold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Capsule().fill(CameraTheme.chromeFill))
        }
    }
}

// MARK: - Overflow menu (top right)

@MainActor
struct OverflowMenu: View {
    let controller: CameraController
    let onOpenSettings: () -> Void
    let onOpenRecipes: () -> Void
    let onExitGuidance: () -> Void
    let onScan: () -> Void

    var body: some View {
        Menu {
            Section("Режим съёмки") {
                Button {
                    controller.mode = .auto
                } label: {
                    Label("Авто", systemImage: controller.mode == .auto ? "checkmark" : "a.circle")
                }
                Button {
                    controller.mode = .manual
                } label: {
                    Label("Ручной", systemImage: controller.mode == .manual ? "checkmark" : "dial.medium")
                }
            }

            Section {
                Button(action: onScan) {
                    Label("Сканировать сцену", systemImage: "viewfinder")
                }
                Button(action: onExitGuidance) {
                    Label("Выйти из наведения", systemImage: "xmark")
                }
                .disabled(controller.mode != .guide)
            } header: {
                Text("Кадрирование")
            }

            Section {
                Button {
                    controller.settings.saveRAW.toggle()
                } label: {
                    Label(
                        controller.settings.saveRAW ? "RAW выкл" : "RAW вкл",
                        systemImage: controller.settings.saveRAW ? "checkmark" : "photo"
                    )
                }
                Button {
                    controller.settings.depthOfFieldEnabled.toggle()
                } label: {
                    Label(
                        controller.settings.depthOfFieldEnabled ? "Боке вкл" : "Боке выкл",
                        systemImage: controller.settings.depthOfFieldEnabled ? "checkmark" : "camera.filters"
                    )
                }
            } header: {
                Text("Съёмка")
            }

            Section {
                Button(action: onOpenRecipes) {
                    Label("Сохранённые кадрирования", systemImage: "bookmark")
                }
                Button(action: onOpenSettings) {
                    Label("Настройки", systemImage: "gearshape")
                }
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 38, height: 38)
                .background(Circle().fill(CameraTheme.chromeFill))
        }
    }
}

// MARK: - Top bar

@MainActor
struct TopBar: View {
    let controller: CameraController
    let onOpenSettings: () -> Void
    let onOpenRecipes: () -> Void
    let onExitGuidance: () -> Void
    let onScan: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            AspectMenu(aspect: Binding(
                get: { controller.settings.aspect },
                set: {
                    controller.settings.aspect = $0
                    // A different aspect invalidates a stored framing.
                    if controller.activeRecipe != nil { controller.clearRecipe() }
                }
            ))

            Spacer(minLength: 0)

            iconButton(
                icon: controller.device.isTorchOn ? "bolt.fill" : "bolt.slash",
                isActive: controller.device.isTorchOn
            ) {
                controller.device.setTorch(!controller.device.isTorchOn)
            }

            iconButton(
                icon: controller.settings.gridStyle == .off
                    ? "square.slash"
                    : controller.settings.gridStyle.icon,
                isActive: controller.settings.gridStyle != .off
            ) {
                let order = GridStyle.allCases
                let current = controller.settings.gridStyle
                controller.settings.gridStyle =
                    order[(order.firstIndex(of: current).map { $0 + 1 } ?? 0) % order.count]
            }

            OverflowMenu(
                controller: controller,
                onOpenSettings: onOpenSettings,
                onOpenRecipes: onOpenRecipes,
                onExitGuidance: onExitGuidance,
                onScan: onScan
            )
        }
        .padding(.horizontal, 16)
    }

    private func iconButton(
        icon: String,
        isActive: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(isActive ? CameraTheme.accent : .white)
                .frame(width: 38, height: 38)
                .background(Circle().fill(CameraTheme.chromeFill))
        }
    }
}

// MARK: - Scan button

/// The scan affordance changes shape with the app state, the way it does in the
/// mockup: a spark to start, a loop to rescan, a cross to bail out.
struct ScanButton: View {
    enum State {
        case idle
        case scanned
        case guiding

        var icon: String {
            switch self {
            case .idle: "sparkles"
            case .scanned: "arrow.clockwise"
            case .guiding: "xmark"
            }
        }

        var label: String {
            switch self {
            case .idle: "Сканировать"
            case .scanned: "Заново"
            case .guiding: "Выйти"
            }
        }

        var isAccented: Bool { self != .guiding }
    }

    let state: State
    let isBusy: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle()
                    .fill(state.isAccented ? CameraTheme.accent.opacity(0.18) : Color.white.opacity(0.12))
                    .frame(width: 62, height: 62)

                if isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .tint(CameraTheme.accent)
                } else {
                    Image(systemName: state.icon)
                        .font(.system(size: 21, weight: .semibold))
                        .foregroundStyle(state.isAccented ? CameraTheme.accent : .white)
                }
            }
        }
        .disabled(isBusy)
        .animation(.snappy(duration: 0.25), value: state)
    }
}

// MARK: - Instruction line

/// One imperative instruction under the preview.
struct InstructionLine: View {
    let text: String
    let tint: Color
    var isProminent: Bool = true

    var body: some View {
        Text(text)
            .font(.system(size: isProminent ? 16 : 13, weight: .semibold, design: .rounded))
            .foregroundStyle(tint)
            .multilineTextAlignment(.center)
            .lineLimit(2)
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity)
            .animation(.snappy(duration: 0.2), value: text)
    }
}

// MARK: - Small badge

struct Badge: View {
    let text: String
    var systemImage: String?
    var tint: Color = .white

    var body: some View {
        HStack(spacing: 4) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .bold))
            }
            Text(text)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Capsule().fill(.black.opacity(0.55)))
    }
}

// MARK: - Permission / error states

struct MessageOverlay: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 42))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 19, weight: .semibold))
            Text(message)
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.borderedProminent)
                    .padding(.top, 4)
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
    }
}