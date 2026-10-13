import SwiftUI

@MainActor
struct SettingsView: View {
    @Environment(CameraController.self) private var controller
    @Environment(\.dismiss) private var dismiss

    private var settings: AppSettings { controller.settings }

    var body: some View {
        NavigationStack {
            Form {
                Section("Сетка") {
                    Picker("Стиль", selection: Binding(
                        get: { settings.gridStyle },
                        set: { settings.gridStyle = $0 }
                    )) {
                        ForEach(GridStyle.allCases) { style in
                            Label(style.displayName, systemImage: style.icon).tag(style)
                        }
                    }

                    VStack(alignment: .leading) {
                        Text("Прозрачность")
                        Slider(value: Binding(
                            get: { settings.gridOpacity },
                            set: { settings.gridOpacity = $0 }
                        ), in: 0.1...0.9)
                    }
                }

                Section("Кадр") {
                    Picker("Соотношение", selection: Binding(
                        get: { settings.aspect },
                        set: { settings.aspect = $0 }
                    )) {
                        ForEach(AspectRatio.allCases) { ratio in
                            Text(ratio.displayName).tag(ratio)
                        }
                    }

                    Toggle("Гистограмма", isOn: Binding(
                        get: { settings.showHistogram },
                        set: { settings.showHistogram = $0 }
                    ))

                    Toggle("Уровень горизонта", isOn: Binding(
                        get: { settings.showLevel },
                        set: { settings.showLevel = $0 }
                    ))
                }

                Section {
                    Toggle("Сохранять RAW (DNG)", isOn: Binding(
                        get: { settings.saveRAW },
                        set: { settings.saveRAW = $0 }
                    ))

                    Toggle("Имитация диафрагмы (боке)", isOn: Binding(
                        get: { settings.depthOfFieldEnabled },
                        set: { settings.depthOfFieldEnabled = $0 }
                    ))

                    Text("У iPhone фиксированная диафрагма — это программная имитация размытия фона по карте глубины.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Съёмка")
                }

                Section {
                    Toggle("Автозум при наведении", isOn: Binding(
                        get: { settings.autoZoom },
                        set: { settings.autoZoom = $0 }
                    ))

                    Toggle("Автоэкспозиция при наведении", isOn: Binding(
                        get: { settings.autoExposure },
                        set: { settings.autoExposure = $0 }
                    ))

                    Toggle("Автоспуск при совпадении", isOn: Binding(
                        get: { settings.autoCapture },
                        set: { settings.autoCapture = $0 }
                    ))

                    VStack(alignment: .leading) {
                        Text("Порог совпадения: \(Int(settings.matchThreshold * 100))%")
                        Slider(value: Binding(
                            get: { settings.matchThreshold },
                            set: { settings.matchThreshold = $0 }
                        ), in: 0.6...0.98)
                    }
                } header: {
                    Text("Наведение")
                } footer: {
                    Text("Любое касание экрана временно возвращает управление камере — она не будет драться с вами.")
                }

                Section("Диагностика") {
                    LabeledContent("Зум", value: String(format: "%.2f×", controller.device.zoomFactor))
                    LabeledContent("Диапазон зума", value: String(
                        format: "%.1f–%.1f×", controller.device.minZoom, controller.device.maxZoom
                    ))
                    LabeledContent("Реальная диафрагма", value: CameraDeviceController.fNumberLabel(
                        Float(controller.device.realAperture)
                    ))
                    LabeledContent("ISO", value: "\(Int(controller.device.limits.minISO))–\(Int(controller.device.limits.maxISO))")
                    LabeledContent("Буфер превью", value: String(format: "%.3f", controller.bufferAspect))
                    LabeledContent("Поворот", value: "\(Int(controller.rotationAngle))°")
                }
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }
}