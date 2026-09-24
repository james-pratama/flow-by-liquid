import SwiftUI

struct OverlayRoot: View {
    @ObservedObject var model: OverlayModel
    var onHover: (Bool) -> Void

    var body: some View {
        VStack(spacing: 8) {
            ForEach(model.cards) { card in
                CardView(card: card, deadline: model.deadlines[card.id], pausedAt: model.pausedAt)
                    .onHover(perform: onHover)
                    .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity),
                                            removal: .opacity.combined(with: .scale(scale: 0.96))))
            }
            Pill(model: model)
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .fixedSize()
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: model.cards.map(\.id))
        .animation(.easeOut(duration: 0.15), value: model.phase)
    }
}

private let pillBlack = Color(red: 24 / 255, green: 24 / 255, blue: 27 / 255)   // zinc-900

struct Pill: View {
    @ObservedObject var model: OverlayModel

    var body: some View {
        Group {
            switch model.phase {
            case .listening:
                HStack(spacing: 8) {
                    if model.dictating {
                        Image(systemName: "text.cursor").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.violet.opacity(0.9))
                    }
                    LevelBars(level: model.level)
                    if model.meetingStartedAt != nil { RecDot() }
                }
                .padding(.horizontal, 14)
                .frame(height: 32)
            case .thinking:
                HStack(spacing: 8) {
                    ThinkingDots()
                    if !model.status.isEmpty {
                        Text(model.status).font(.system(size: 12, weight: .medium)).foregroundStyle(.white.opacity(0.85))
                            .lineLimit(1).frame(maxWidth: 300)
                    }
                }
                .padding(.horizontal, 14)
                .frame(height: 32)
            case .idle:
                if let start = model.meetingStartedAt {
                    TimelineView(.periodic(from: .now, by: 1)) { ctx in
                        HStack(spacing: 6) {
                            RecDot()
                            Text(Self.elapsed(from: start, to: ctx.date)).font(.system(size: 11, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.white.opacity(0.9))
                        }
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 22)
                } else {
                    Color.clear.frame(width: 40, height: 7)
                }
            }
        }
        .background(Capsule().fill(pillBlack.opacity(model.phase == .idle && model.meetingStartedAt == nil ? 0.55 : 0.94)))
        .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
    }

    static func elapsed(from: Date, to: Date) -> String {
        let s = Int(to.timeIntervalSince(from))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s / 60) % 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }
}

struct RecDot: View {
    @State private var on = true
    var body: some View {
        Circle().fill(Color.red).frame(width: 7, height: 7).opacity(on ? 1 : 0.35)
            .onAppear { withAnimation(.easeInOut(duration: 0.8).repeatForever()) { on.toggle() } }
    }
}

struct LevelBars: View {
    var level: Float
    private let weights: [CGFloat] = [0.45, 0.7, 1.0, 0.8, 0.55, 0.9, 0.6, 0.4, 0.75]
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 3) {
                ForEach(weights.indices, id: \.self) { i in
                    let wobble = CGFloat(0.75 + 0.25 * sin(t * 9 + Double(i) * 1.3))
                    let amp = min(1, CGFloat(level) * 14)
                    Capsule().fill(.white)
                        .frame(width: 3, height: 4 + 16 * amp * weights[i] * wobble)
                }
            }
            .frame(height: 20)
        }
    }
}

struct ThinkingDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            HStack(spacing: 4) {
                ForEach(0..<3) { i in
                    Circle().fill(.white).frame(width: 5, height: 5)
                        .opacity(0.35 + 0.65 * max(0, sin(t * 5 - Double(i) * 0.7)))
                }
            }
        }
    }
}

/// Depleting ring: how long until the card disappears. Freezes while hovered.
struct CountdownRing: View {
    let deadline: Date
    let total: TimeInterval
    let pausedAt: Date?
    let tint: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30, paused: pausedAt != nil)) { ctx in
            let left = deadline.timeIntervalSince(pausedAt ?? ctx.date)
            let progress = max(0, min(1, left / max(total, 0.1)))
            ZStack {
                Circle().stroke(Color.white.opacity(0.14), lineWidth: 2)
                Circle().trim(from: 0, to: progress)
                    .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            .frame(width: 13, height: 13)
        }
    }
}

struct CardView: View {
    let card: Card
    let deadline: Date?
    let pausedAt: Date?

    private var tint: Color {
        switch card.style {
        case .success: return .green
        case .answer: return Color(red: 0.65, green: 0.55, blue: 0.98)   // violet-400
        case .info: return .white.opacity(0.7)
        case .warning, .confirm: return .orange
        case .error: return .red
        case .reminder: return .pink
        case .meeting: return Color(red: 0.3, green: 0.85, blue: 0.6)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: card.symbol).foregroundStyle(tint).font(.system(size: 13, weight: .semibold))
                Text(card.title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.white)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if let deadline, let total = card.seconds {
                    CountdownRing(deadline: deadline, total: total, pausedAt: pausedAt, tint: tint)
                }
                Button { let id = card.id; Task { @MainActor in Overlay.shared.dismiss(id, runTimeout: true) } } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(.white.opacity(0.5))
                }
                .buttonStyle(.plain)
            }
            if card.working {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(card.steps) { step in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            ZStack {
                                if step.done {
                                    Image(systemName: "checkmark").font(.system(size: 9, weight: .bold)).foregroundStyle(tint)
                                } else {
                                    Spinner(tint: tint)
                                }
                            }
                            .frame(width: 12, height: 12)
                            Text(step.text).font(.system(size: 12))
                                .foregroundStyle(.white.opacity(step.done ? 0.6 : 0.92))
                                .lineLimit(2)
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .animation(.easeOut(duration: 0.2), value: card.steps)
            }
            if !card.body.isEmpty {
                Text(card.body).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.88))
                    .lineLimit(card.style == .answer ? 9 : 4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !card.footnote.isEmpty {
                Text(card.footnote).font(.system(size: 11)).foregroundStyle(.white.opacity(0.5)).lineLimit(2)
            }
            if !card.actions.isEmpty {
                HStack(spacing: 6) {
                    Spacer()
                    ForEach(card.actions) { a in
                        Button { let id = card.id; Task { @MainActor in Overlay.shared.perform(a, on: id) } } label: {
                            Text(a.title).font(.system(size: 12, weight: .semibold))
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .foregroundStyle(a.destructive ? Color.red : Color.white)
                                .background(Capsule().fill(a.primary ? Theme.violet : Color.white.opacity(0.12)))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(14)
        .frame(width: 400, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(pillBlack.opacity(0.96)))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.3), radius: 16, y: 6)
    }
}

/// Small rotating arc for the step in progress (matches the countdown rings).
struct Spinner: View {
    let tint: Color
    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 30)) { ctx in
            let angle = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9 * 360
            ZStack {
                Circle().stroke(Color.white.opacity(0.14), lineWidth: 1.8)
                Circle().trim(from: 0, to: 0.3)
                    .stroke(tint, style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                    .rotationEffect(.degrees(angle))
            }
            .frame(width: 11, height: 11)
        }
    }
}
