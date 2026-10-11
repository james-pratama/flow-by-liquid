import AppKit
import SwiftUI
import Combine

final class PetModel: ObservableObject {
    /// The sprite frame on screen.
    @Published var frame: PetSprites.Frame?
    @Published var hovering = false
    @Published var pressed = false
    @Published var dragging = false
    /// The input bar is open and has the keyboard.
    @Published var expanded = false
    @Published var text = ""
}

/// Takes the keyboard for the input bar without activating the app, and lets the pet see mouse
/// events first so a press on Smiley can become either a click or a drag.
final class PetPanel: NSPanel {
    var intercept: ((NSEvent) -> Bool)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func sendEvent(_ event: NSEvent) {
        if intercept?(event) == true { return }
        super.sendEvent(event)
    }
}

/// The desktop pet: Smiley floats above other windows. Click it to talk, drag it anywhere,
/// hover it for an input bar to type a request instead of speaking it.
@MainActor
final class Pet {
    static let shared = Pet()

    static let top: CGFloat = 2
    static let barGap: CGFloat = 2
    static let barSize = NSSize(width: 280, height: 34)
    /// The panel never resizes: it is wide enough for the open input bar, and its empty parts are click-through.
    static let size = NSSize(width: barSize.width + 20, height: top + PetSprites.size.height + barGap + barSize.height + 10)
    static let spring = Animation.spring(response: 0.38, dampingFraction: 0.72)

    let model = PetModel()
    private var panel: PetPanel!
    private var sprites: PetSprites!
    private var bag: Set<AnyCancellable> = []
    /// Where the user was before the input bar took the keyboard, so "write it here" still knows where "here" is.
    private var focus: FocusContext?
    private var grab: (mouse: CGPoint, origin: CGPoint)?
    private var hoverEnd: Task<Void, Never>?
    private var lastCard: UUID?

    func setup() {
        guard let sprites = PetSprites.load() else {
            smileyLog("desktop pet unavailable: Resources/Pet (spritesheet.png, manifest.json) not found")
            return
        }
        self.sprites = sprites
        panel = PetPanel(contentRect: NSRect(origin: .zero, size: Self.size),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.intercept = { [weak self] ev in self?.intercept(ev) ?? false }
        panel.contentView = NSHostingView(rootView: PetRoot(
            pet: model, overlay: Overlay.shared.model,
            onHover: { [weak self] h in self?.hover(h) }, onExpand: { [weak self] in self?.expand() },
            onSubmit: { [weak self] in self?.submit() }, onTalk: { [weak self] in self?.tap() }))
        panel.setFrameOrigin(clamped(savedOrigin ?? defaultOrigin))

        NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.collapse() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.settle() }
        }
        let overlay = Overlay.shared.model
        overlay.$cards.sink { [weak self] cards in self?.react(to: cards.first) }.store(in: &bag)
        // Published values arrive before they are stored, so read the overlay on the next turn.
        overlay.$phase.map { _ in () }.merge(with: overlay.$cards.map { _ in () })
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &bag)
        Settings.shared.$showPet.sink { [weak self] show in self?.setVisible(show) }.store(in: &bag)
    }

    private func setVisible(_ show: Bool) {
        lookTimer?.invalidate()
        frameTimer?.invalidate()
        guard show else { collapse(); panel.orderOut(nil); return }
        panel.orderFrontRegardless()
        let look = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.followMouse() }
        }
        look.tolerance = 0.05
        lookTimer = look
        play(.waving, once: true)   // hello
    }

    // MARK: Position

    private var savedOrigin: CGPoint? {
        UserDefaults.standard.string(forKey: "petOrigin").map(NSPointFromString)
    }

    /// Bottom-right corner of the main screen.
    private var defaultOrigin: CGPoint {
        let vf = NSScreen.main?.visibleFrame ?? .zero
        return CGPoint(x: vf.maxX - 24 - (Self.size.width + PetSprites.size.width) / 2, y: vf.minY + 24)
    }

    /// Smiley's cell, in the panel's coordinates (origin bottom-left).
    private static let spriteRect = CGRect(x: (size.width - PetSprites.size.width) / 2, y: size.height - top - PetSprites.size.height,
                                           width: PetSprites.size.width, height: PetSprites.size.height)

    /// Keeps Smiley on its screen. The panel's empty sides may hang off the edge unless `whole` is set.
    private func clamped(_ origin: CGPoint, whole: Bool = false) -> CGPoint {
        let center = CGPoint(x: origin.x + Self.size.width / 2, y: origin.y + Self.size.height / 2)
        let screen = NSScreen.screens.first { $0.frame.contains(center) } ?? NSScreen.main
        guard let vf = screen?.visibleFrame else { return origin }
        let overhang = whole ? -6 : Self.spriteRect.minX
        return CGPoint(x: min(max(origin.x, vf.minX - overhang), vf.maxX - Self.size.width + overhang),
                       y: min(max(origin.y, vf.minY), vf.maxY - Self.size.height))
    }

    /// Slides back inside the screen if needed, and remembers the spot.
    private func settle(whole: Bool = false) {
        let target = clamped(panel.frame.origin, whole: whole)
        if target != panel.frame.origin {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().setFrame(NSRect(origin: target, size: Self.size), display: true)
            }
        }
        UserDefaults.standard.set(NSStringFromPoint(target), forKey: "petOrigin")
    }

    // MARK: Click and drag

    private func intercept(_ ev: NSEvent) -> Bool {
        switch ev.type {
        case .leftMouseDown:
            guard let box = model.frame?.box,
                  box.offsetBy(dx: Self.spriteRect.minX, dy: Self.top).contains(CGPoint(x: ev.locationInWindow.x, y: Self.size.height - ev.locationInWindow.y))
            else { return false }
            grab = (NSEvent.mouseLocation, panel.frame.origin)
            model.pressed = true
            return true
        case .leftMouseDragged:
            guard let grab else { return false }
            let m = NSEvent.mouseLocation
            if !model.dragging && hypot(m.x - grab.mouse.x, m.y - grab.mouse.y) < 4 { return true }
            let dx = grab.origin.x + m.x - grab.mouse.x - panel.frame.minX
            if !model.dragging { model.dragging = true; heading = dx < 0 ? .runningLeft : .runningRight; refresh() }
            // Runs the way it is carried; small wobbles don't turn it around.
            if abs(dx) > 3, (dx < 0) != (heading == .runningLeft) { heading = dx < 0 ? .runningLeft : .runningRight; refresh() }
            panel.setFrameOrigin(CGPoint(x: grab.origin.x + m.x - grab.mouse.x, y: grab.origin.y + m.y - grab.mouse.y))
            return true
        case .leftMouseUp:
            guard grab != nil else { return false }
            grab = nil
            model.pressed = false
            if model.dragging { model.dragging = false; refresh(); settle(whole: model.expanded) } else { tap() }
            return true
        case .keyDown where ev.keyCode == 53 && model.expanded:   // Esc
            collapse()
            return true
        default:
            return false
        }
    }

    private func tap() {
        collapse()
        SmileyEngine.shared.toggleTalk()
    }

    // MARK: Input bar

    private func hover(_ inside: Bool) {
        hoverEnd?.cancel()
        hoverEnd = nil
        if inside {
            if !model.hovering, clip == .idle, !once { play(.jumping, once: true) }
            withAnimation(Self.spring) { model.hovering = true }
        } else {
            // Long enough to cross the gap between Smiley and the bar.
            hoverEnd = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(350))
                guard !Task.isCancelled, let self else { return }
                self.hoverEnd = nil
                withAnimation(.easeOut(duration: 0.2)) { self.model.hovering = false }
            }
        }
    }

    /// Smiley and the closed input bar under it, in screen coordinates.
    private var hoverZone: CGRect {
        CGRect(x: panel.frame.minX + Self.spriteRect.minX, y: panel.frame.minY, width: Self.spriteRect.width, height: Self.size.height)
    }

    private func expand() {
        guard !model.expanded else { return }
        focus = FocusContext.capture()
        panel.makeKey()
        settle(whole: true)   // near a screen edge, scoot over so the whole bar fits
        withAnimation(Self.spring) { model.expanded = true }
    }

    private func collapse() {
        guard model.expanded else { return }
        withAnimation(Self.spring) { model.expanded = false }
        // Hand the keyboard back to the app the user was in.
        if panel.isKeyWindow {
            panel.orderOut(nil)
            if Settings.shared.showPet { panel.orderFrontRegardless() }
        }
    }

    private func submit() {
        let text = model.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        model.text = ""
        collapse()
        let focus = self.focus
        Task { await SmileyEngine.shared.handle(text, focus: focus) }
    }

    // MARK: Animation

    private var clip = PetSprites.Clip.idle
    private var index = 0
    /// The current clip plays through once, then gives way to `base`.
    private var once = false
    private var frameTimer: Timer?
    private var lookTimer: Timer?
    /// Which way it runs while being dragged.
    private var heading = PetSprites.Clip.runningRight
    /// The pose facing the pointer, while the pointer is moving nearby.
    private var lookPose: Int?
    private var lastMouse = CGPoint.zero
    private var lastMoved = Date.distantPast

    /// The loop that fits what Smiley is doing right now.
    private var base: PetSprites.Clip {
        if model.dragging { return heading }
        let overlay = Overlay.shared.model
        switch overlay.phase {
        case .listening: return .waiting
        case .thinking: return .running
        case .idle: return overlay.cards.contains { $0.style == .confirm } ? .waiting : .idle
        }
    }

    private func play(_ clip: PetSprites.Clip, once: Bool = false) {
        guard !sprites.frames(clip).isEmpty else { return }
        self.clip = clip
        self.once = once
        index = 0
        show()
    }

    /// Shows the current frame for as long as the artwork says it should last.
    private func show() {
        frameTimer?.invalidate()
        let frames = sprites.frames(clip)
        render()
        frameTimer = Timer.scheduledTimer(withTimeInterval: frames[index].duration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.advance() }
        }
    }

    private func advance() {
        if index + 1 < sprites.frames(clip).count { index += 1 }
        else if once { play(base); return }
        else { index = 0 }
        show()
    }

    private func render() {
        if clip == .idle, let lookPose, sprites.looks.indices.contains(lookPose) { model.frame = sprites.looks[lookPose] }
        else { model.frame = sprites.frames(clip)[index] }
    }

    /// Switches loops when the situation changes. A one-off reaction finishes first, unless there is work to show.
    private func refresh() {
        guard Settings.shared.showPet else { return }
        let base = self.base
        if once ? base != .idle : clip != base { play(base) }
    }

    /// Looks over a finished result, or slumps at a failed one.
    private func react(to card: Card?) {
        guard let card, !card.working, card.id != lastCard else { return }
        lastCard = card.id
        guard Settings.shared.showPet else { return }
        switch card.style {
        case .success, .answer: play(.review, once: true)
        case .warning, .error: play(.failed, once: true)
        case .info, .reminder, .meeting, .confirm: break
        }
    }

    /// Turns to face the pointer while it moves nearby, then settles back into the idle loop.
    private func followMouse() {
        let m = NSEvent.mouseLocation
        let now = Date()
        if m != lastMouse { lastMouse = m; lastMoved = now }
        let c = CGPoint(x: panel.frame.midX, y: panel.frame.minY + Self.spriteRect.midY)
        let dx = m.x - c.x, dy = m.y - c.y
        let distance = hypot(dx, dy)
        let pose = distance > 70 && distance < 450 && now.timeIntervalSince(lastMoved) < 1.5 ? sprites.look(dx: dx, dy: dy) : nil
        if pose != lookPose {
            lookPose = pose
            if clip == .idle { render() }
        }
        // The panel's empty parts are click-through, so it isn't always told when the pointer leaves Smiley.
        if model.hovering && !hoverZone.contains(m) && hoverEnd == nil { hover(false) }
    }
}
