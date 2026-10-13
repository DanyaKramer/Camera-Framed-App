import SwiftUI

/// Live guidance while the user walks the camera onto the target framing.
///
/// Three visual states, matching the mockup:
///   - `.guiding` — dashed box around the detected subject, a leader line to the
///     frame centre, one imperative instruction.
///   - `.aligned` — green crosshair at the centre, subject label, "можно снимать".
///   - `.idle`    — nothing.
///
/// The subject box is the important part: a bare crosshair says "move", a box
/// says "move *this*".
struct GuidanceOverlay: View {
    let geometry: CaptureGeometry
    let match: MatchResult
    let phase: GuidancePhase
    let streak: Int
    let requiredStreak: Int
    /// Normalised to the visible frame, like every other analysis coordinate.
    let subjectBounds: CGRect?
    let subjectLabel: String

    private var tint: Color { CameraTheme.tint(for: phase) }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let center = CGPoint(x: size.width / 2, y: size.height / 2)

            ZStack {
                if phase == .guiding, let subjectBounds {
                    SubjectBox(
                        rect: geometry.rect(geometry.toLocal(subjectBounds), in: size),
                        center: center,
                        tint: tint
                    )
                }

                Crosshair(center: center, tint: tint, weight: phase == .aligned ? 2.0 : 1.4)

                if let subjectBounds {
                    subjectLabelView(size: size, bounds: geometry.toLocal(subjectBounds))
                }

                LevelTicks(center: center, tint: tint)
            }
            .overlay(alignment: .topTrailing) {
                MatchRing(match: match.match, streak: streak, requiredStreak: requiredStreak, tint: tint)
                    .padding(.trailing, 14)
                    .padding(.top, 14)
            }
        }
        .allowsHitTesting(false)
    }

    /// Label sits under the subject box while adjusting, and at the centre when
    /// the framing has already landed — there is nothing to point at then.
    @ViewBuilder
    private func subjectLabelView(size: CGSize, bounds: CGRect) -> some View {
        let isAdjusting = phase == .guiding && abs(bounds.midY - 0.5) > 0.02
        let anchor = isAdjusting
            ? CGPoint(x: bounds.midX * size.width, y: bounds.maxY * size.height)
            : CGPoint(x: size.width / 2, y: size.height / 2 + 26)

        HStack(spacing: 6) {
            Circle()
                .fill(tint)
                .frame(width: 7, height: 7)
            Text(subjectLabel)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .foregroundStyle(tint)
                .lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(
            Capsule().fill(.black.opacity(0.42))
        )
        .position(anchor)
    }
}

/// Dashed outline around the detected subject plus a leader line to the centre,
/// so the direction of travel is unambiguous.
struct SubjectBox: View {
    let rect: CGRect
    let center: CGPoint
    let tint: Color

    var body: some View {
        Canvas { context, _ in
            var outline = Path(roundedRect: rect, cornerRadius: 12)
            context.stroke(
                outline,
                with: .color(tint),
                style: StrokeStyle(lineWidth: 2.2, lineCap: .round, dash: [9, 7])
            )

            // Leader line: from the top-centre of the box to the frame centre.
            let anchor = CGPoint(x: rect.midX, y: rect.minY)
            var leader = Path()
            leader.move(to: anchor)
            leader.addLine(to: center)
            context.stroke(
                leader,
                with: .color(tint.opacity(0.7)),
                style: StrokeStyle(lineWidth: 1.4, dash: [5, 6])
            )

            // Small tick at the box end of the leader.
            var tick = Path()
            tick.move(to: CGPoint(x: anchor.x - 5, y: anchor.y - 5))
            tick.addLine(to: CGPoint(x: anchor.x + 5, y: anchor.y + 5))
            context.stroke(tick, with: .color(tint.opacity(0.8)), lineWidth: 1.6)
        }
    }
}

/// Frame-centre target mark.
struct Crosshair: View {
    let center: CGPoint
    let tint: Color
    let weight: CGFloat

    var body: some View {
        Path { path in
            let arm: CGFloat = 16
            let gap: CGFloat = 9
            path.move(to: CGPoint(x: center.x - arm, y: center.y))
            path.addLine(to: CGPoint(x: center.x - gap, y: center.y))
            path.move(to: CGPoint(x: center.x + gap, y: center.y))
            path.addLine(to: CGPoint(x: center.x + arm, y: center.y))
            path.move(to: CGPoint(x: center.x, y: center.y - arm))
            path.addLine(to: CGPoint(x: center.x, y: center.y - gap))
            path.move(to: CGPoint(x: center.x, y: center.y + gap))
            path.addLine(to: CGPoint(x: center.x, y: center.y + arm))
        }
        .stroke(tint, style: StrokeStyle(lineWidth: weight, lineCap: .round))
    }
}

/// Fixed reference marks flanking the centre, next to the live horizon line.
struct LevelTicks: View {
    let center: CGPoint
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Rectangle().fill(Color.white.opacity(0.5)).frame(width: 26, height: 1)
            Rectangle().fill(tint).frame(width: 26, height: 1.5)
            Rectangle().fill(Color.white.opacity(0.5)).frame(width: 26, height: 1)
        }
        .position(center)
        .allowsHitTesting(false)
    }
}

struct MatchRing: View {
    let match: Double
    let streak: Int
    let requiredStreak: Int
    let tint: Color

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Circle()
                    .stroke(.white.opacity(0.18), lineWidth: 3.5)
                Circle()
                    .trim(from: 0, to: match)
                    .stroke(tint, style: StrokeStyle(lineWidth: 3.5, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.easeOut(duration: 0.18), value: match)

                Text("\(Int(match * 100))")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
                    .overlay(alignment: .trailing) {
                        Text("%")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white.opacity(0.6))
                            .offset(x: 8)
                    }
            }
            .frame(width: 52, height: 52)

            if requiredStreak > 1 && streak > 0 {
                HStack(spacing: 3) {
                    ForEach(0..<requiredStreak, id: \.self) { index in
                        Capsule()
                            .fill(index < streak ? tint : Color.white.opacity(0.25))
                            .frame(width: 9, height: 3)
                    }
                }
            }
        }
        .animation(.snappy(duration: 0.2), value: streak)
    }
}