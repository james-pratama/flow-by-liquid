import AppKit
import SwiftUI
import Combine

enum CardStyle { case success, answer, info, warning, error, reminder, meeting, confirm }

struct CardAction: Identifiable {
    let id = UUID()
    var title: String
    var primary = false
    var destructive = false
    var handler: @MainActor () -> Void
}

struct CardStep: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var done = false
}

struct Card: Identifiable {
    let id = UUID()
    /// A "working" card lists the agent's steps live (spinner on the current one) until the answer arrives.
    var steps: [CardStep] = []
    var working = false
    var style: CardStyle
    var symbol: String
    var title: String
    var body: String = ""
    var footnote: String = ""
    var actions: [CardAction] = []
    /// Lower shows first. Confirmations 0, reminders/meetings 1, results 2.
    var priority: Int = 2
    /// nil = stays until the user acts on it.
    var seconds: Double? = 4
    var onTimeout: (() -> Void)? = nil
}

final class OverlayModel: ObservableObject {
    enum Phase: Equatable { case idle, listening, thinking }
    @Published var phase: Phase = .idle
    @Published var level: Float = 0
    @Published var status: String = ""
    /// Visible cards, newest first (drawn on top, above older ones).
    @Published var cards: [Card] = []
    /// When each timed card disappears.
    @Published var deadlines: [UUID: Date] = [:]
    /// Set while the pointer is over a card: every countdown freezes.
    @Published var pausedAt: Date?
    @Published var meetingStartedAt: Date?
    /// Listening for plain dictation (second hotkey) rather than a command.
    @Published var dictating = false
    @Published var showIdle = Settings.shared.showIdlePill
}

/// The bottom-of-screen pill and result cards. A non-activating panel, so it never steals focus
/// from the app the user is typing in.
@MainActor
final class Overlay {
    static let shared = Overlay()

    let model = OverlayModel()
    private var panel: NSPanel!
    private var host: NSHostingView<OverlayRoot>!
    private var bag: Set<AnyCancellable> = []

    func setup() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 460, height: 60),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        host = NSHostingView(rootView: OverlayRoot(model: model, onHover: { [weak self] h in self?.hover(h) }))
        panel.contentView = host
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.relayout() } }
            .store(in: &bag)
        Settings.shared.$showIdlePill.sink { [weak self] v in self?.model.showIdle = v }.store(in: &bag)
        relayout()
        panel.orderFrontRegardless()
    }

    private func relayout() {
        guard let panel, let host else { return }
        let size = host.fittingSize
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return }
        let w = max(size.width, 60), h = max(size.height, 20)
        panel.setFrame(NSRect(x: vf.midX - w / 2, y: vf.minY + 10, width: w, height: h), display: true)
        panel.ignoresMouseEvents = model.cards.isEmpty
        let visible = model.phase != .idle || !model.cards.isEmpty || model.showIdle || model.meetingStartedAt != nil
        panel.alphaValue = visible ? 1 : 0
        panel.orderFrontRegardless()
    }

    // MARK: Pill

    func listening(dictating: Bool = false) { model.phase = .listening; model.dictating = dictating; model.status = ""; model.level = 0 }
    func thinking(_ status: String) { model.phase = .thinking; model.status = status }
    func idle() { model.phase = .idle; model.status = ""; model.level = 0 }
    func level(_ v: Float) { model.level = v }

    // MARK: Cards

    static let maxCards = 4
    private var timers: [UUID: Timer] = [:]
    private var remaining: [UUID: TimeInterval] = [:]

    /// New cards appear on top of the stack; each timed card counts down on its own and disappears.
    func show(_ card: Card) {
        model.cards.insert(card, at: 0)
        if let secs = card.seconds { schedule(card.id, after: secs) }
        while model.cards.count > Self.maxCards, let oldest = model.cards.last {
            dismiss(oldest.id, runTimeout: true)
        }
    }

    func result(_ title: String, _ body: String = "", style: CardStyle = .success, symbol: String? = nil,
                seconds: Double? = nil, actions: [CardAction] = []) {
        show(Card(style: style, symbol: symbol ?? Self.symbol(style), title: title, body: body, actions: actions,
                  priority: 2, seconds: seconds ?? Settings.shared.resultSeconds))
    }

    /// Asks the user to approve an "Ask first" tool. Resolves false on timeout.
    func confirm(_ title: String, _ body: String) async -> Bool {
        await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            var resolved = false
            let finish: (Bool) -> Void = { v in if !resolved { resolved = true; cont.resume(returning: v) } }
            show(Card(style: .confirm, symbol: "hand.raised.fill", title: title, body: body,
                      actions: [CardAction(title: "Cancel") { finish(false) }, CardAction(title: "Do it", primary: true) { finish(true) }],
                      priority: 0, seconds: 30, onTimeout: { finish(false) }))
        }
    }

    // MARK: Working card (live agent steps)

    func beginWork(_ title: String) -> UUID {
        let card = Card(steps: [], working: true, style: .answer, symbol: "sparkle", title: title, priority: 2, seconds: nil)
        show(card)
        return card.id
    }

    @discardableResult
    func addStep(_ card: UUID, _ text: String) -> UUID {
        let step = CardStep(text: text)
        if let i = model.cards.firstIndex(where: { $0.id == card }) {
            for j in model.cards[i].steps.indices { model.cards[i].steps[j].done = true }
            model.cards[i].steps.append(step)
        }
        flowLog("step: \(text)")
        return step.id
    }

    func finishStep(_ card: UUID, _ step: UUID, _ text: String? = nil) {
        guard let i = model.cards.firstIndex(where: { $0.id == card }),
              let j = model.cards[i].steps.firstIndex(where: { $0.id == step }) else { return }
        model.cards[i].steps[j].done = true
        if let text { model.cards[i].steps[j].text = text; flowLog("step: \(text)") }
    }

    func dismiss(_ id: UUID, runTimeout: Bool = false) {
        timers[id]?.invalidate()
        timers[id] = nil
        remaining[id] = nil
        model.deadlines[id] = nil
        guard let i = model.cards.firstIndex(where: { $0.id == id }) else { return }
        let card = model.cards.remove(at: i)
        if runTimeout { card.onTimeout?() }
    }

    func perform(_ action: CardAction, on id: UUID) {
        if let i = model.cards.firstIndex(where: { $0.id == id }) { model.cards[i].onTimeout = nil }
        action.handler()
        dismiss(id)
    }

    private func schedule(_ id: UUID, after secs: TimeInterval) {
        timers[id]?.invalidate()
        if model.pausedAt != nil { remaining[id] = secs; model.deadlines[id] = Date().addingTimeInterval(secs); return }
        model.deadlines[id] = Date().addingTimeInterval(secs)
        timers[id] = Timer.scheduledTimer(withTimeInterval: secs, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss(id, runTimeout: true) }
        }
    }

    private func hover(_ h: Bool) {
        if h {
            guard model.pausedAt == nil else { return }
            let now = Date()
            model.pausedAt = now
            for (id, t) in timers {
                t.invalidate()
                remaining[id] = max(0.5, (model.deadlines[id] ?? now).timeIntervalSince(now))
            }
            timers.removeAll()
        } else {
            guard model.pausedAt != nil else { return }
            model.pausedAt = nil
            let left = remaining
            remaining.removeAll()
            for (id, secs) in left { schedule(id, after: secs) }
        }
    }

    static func symbol(_ s: CardStyle) -> String {
        switch s {
        case .success: return "checkmark.circle.fill"
        case .answer: return "sparkle"
        case .info: return "info.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        case .reminder: return "bell.fill"
        case .meeting: return "person.2.wave.2.fill"
        case .confirm: return "hand.raised.fill"
        }
    }
}
