import SwiftUI

/// Shown after a Scan: what was found, and the buttons to act on it.
struct ScanReviewView: View {
    let recipe: FramingRecipe
    let onApply: () -> Void
    let onRescan: () -> Void
    let onSave: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Text("Найденный кадр")
                    .font(.system(size: 17, weight: .bold))
                Spacer()
                Button("Отмена", action: onCancel)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
            }

            preview
                .frame(maxWidth: 220)
                .frame(maxHeight: 280)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(.white.opacity(0.18), lineWidth: 1)
                )

            badges

            Spacer(minLength: 0)

            VStack(spacing: 10) {
                Button(action: onApply) {
                    Text("Применить кадрирование")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(RoundedRectangle(cornerRadius: 14).fill(.white))
                        .foregroundStyle(.black)
                }

                HStack(spacing: 10) {
                    Button(action: onRescan) {
                        Label("Заново", systemImage: "arrow.clockwise")
                            .font(.system(size: 14, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.14)))
                    }
                    Button(action: onSave) {
                        Label("Сохранить", systemImage: "bookmark")
                            .font(.system(size: 14, weight: .medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .background(RoundedRectangle(cornerRadius: 12).fill(.white.opacity(0.14)))
                    }
                }
            }
        }
        .foregroundStyle(.white)
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            LinearGradient(
                colors: [.black.opacity(0.92), .black.opacity(0.99)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    @ViewBuilder
    private var preview: some View {
        if let image = recipe.thumbnailImage {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
        } else {
            ZStack {
                Color.white.opacity(0.06)
                Image(systemName: "photo")
                    .font(.system(size: 34))
                    .foregroundStyle(.white.opacity(0.3))
            }
        }
    }

    private var badges: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                Badge(text: recipe.zoomLabel, systemImage: "plus.magnifyingglass")
                Badge(text: recipe.evLabel, systemImage: "sun.max")
                Badge(
                    text: recipe.rollLabel,
                    systemImage: "level",
                    tint: abs(recipe.rollDegrees) < 1 ? .green : .yellow
                )
            }
            HStack(spacing: 6) {
                Badge(text: "Кадр \(Int(recipe.confidence * 100))%", systemImage: "sparkles")
                Badge(text: recipe.subjectKind, systemImage: "person.crop.square")
            }

            if recipe.clippedFraction > 0.01 {
                Text("Пересвет \(Int(recipe.clippedFraction * 100))% — камера затемнит кадр")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }
        }
    }
}

/// Saved framings, reusable for a series of shots.
struct RecipeGalleryView: View {
    let controller: CameraController
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if controller.savedRecipes.isEmpty {
                    ContentUnavailableView(
                        "Пока пусто",
                        systemImage: "bookmark",
                        description: Text("Отсканируйте кадр и сохраните его, чтобы переиспользовать кадрирование.")
                    )
                } else {
                    ScrollView {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 12)], spacing: 12) {
                            ForEach(controller.savedRecipes) { recipe in
                                Button {
                                    controller.useRecipe(recipe)
                                    dismiss()
                                } label: {
                                    VStack(alignment: .leading, spacing: 6) {
                                        thumb(recipe)
                                            .frame(height: 150)
                                            .frame(maxWidth: .infinity)
                                            .background(
                                                RoundedRectangle(cornerRadius: 10)
                                                    .fill(.white.opacity(0.06))
                                            )
                                            .clipShape(RoundedRectangle(cornerRadius: 10))
                                        HStack {
                                            Text(recipe.aspect.displayName)
                                            Spacer()
                                            Text(recipe.zoomLabel)
                                        }
                                        .font(.system(size: 11, weight: .medium, design: .rounded))
                                        .foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Кадрирования")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func thumb(_ recipe: FramingRecipe) -> some View {
        if let image = recipe.thumbnailImage {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .clipped()
        } else {
            Color.clear
        }
    }
}