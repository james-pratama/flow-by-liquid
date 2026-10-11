import SwiftUI

struct PetRoot: View {
    @ObservedObject var pet: PetModel
    @ObservedObject var overlay: OverlayModel
    var onHover: (Bool) -> Void
    var onExpand: () -> Void
    var onSubmit: () -> Void
    var onTalk: () -> Void

    private var barVisible: Bool { pet.expanded || (pet.hovering && !pet.dragging) }

    var body: some View {
        VStack(spacing: Pet.barGap) {
            ZStack(alignment: .topLeading) {
                if let frame = pet.frame {
                    Image(decorative: frame.image, scale: 2).interpolation(.high)
                        .frame(width: frame.box.width, height: frame.box.height)
                        .offset(x: frame.box.minX, y: frame.box.minY)
                }
            }
            .frame(width: PetSprites.size.width, height: PetSprites.size.height, alignment: .topLeading)
            // A soft shadow where the boots touch the ground.
            .background(alignment: .bottom) {
                Ellipse().fill(.black.opacity(0.2)).frame(width: 46, height: 7).blur(radius: 3).offset(y: -1)
            }
            .overlay(alignment: .topTrailing) { badge.offset(x: -2, y: 14) }
            .scaleEffect(pet.pressed ? 0.94 : 1, anchor: .bottom)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: pet.pressed)
            .contextMenu {
                Button("Open Smiley") { AppNavigator.shared.showWindow() }
                Button("Hide the desktop pet") { Settings.shared.showPet = false }
            }
            .accessibilityElement()
            .accessibilityLabel("Smiley")
            .accessibilityHint("Click to talk, drag to move")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, onTalk)
            PetInputBar(pet: pet, onExpand: onExpand, onSubmit: onSubmit)
                .opacity(barVisible ? 1 : 0)
                .scaleEffect(barVisible ? 1 : 0.7, anchor: .top)
                .offset(y: barVisible ? 0 : -10)
                .allowsHitTesting(barVisible)
        }
        .onHover(perform: onHover)
        .padding(.top, Pet.top)
        .frame(width: Pet.size.width, height: Pet.size.height, alignment: .top)
    }

    /// What Smiley is busy with, beside its head: the mic level, thinking dots, or a recording light.
    @ViewBuilder
    private var badge: some View {
        Group {
            switch overlay.phase {
            case .listening: LevelBars(level: overlay.level).scaleEffect(0.6).frame(width: 34, height: 14)
            case .thinking: ThinkingDots().scaleEffect(0.8).frame(width: 22, height: 8)
            case .idle: if overlay.meetingStartedAt != nil { RecDot() }
            }
        }
        .padding(.horizontal, 6).padding(.vertical, 5)
        .background(Capsule().fill(Theme.popup.opacity(0.94)))
        .opacity(overlay.phase != .idle || overlay.meetingStartedAt != nil ? 1 : 0)
        .animation(.easeOut(duration: 0.15), value: overlay.phase)
    }
}

/// The input bar under the pet: a small "Type" chip on hover that springs open into a text field when clicked.
struct PetInputBar: View {
    @ObservedObject var pet: PetModel
    var onExpand: () -> Void
    var onSubmit: () -> Void
    @FocusState private var focused: Bool

    private var empty: Bool { pet.text.trimmingCharacters(in: .whitespaces).isEmpty }

    var body: some View {
        ZStack {
            if pet.expanded {
                HStack(spacing: 8) {
                    TextField("", text: $pet.text, prompt: Text("Ask Smiley anything…").foregroundColor(.white.opacity(0.4)))
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundStyle(.white)
                        .tint(.white)
                        .focused($focused)
                        .onSubmit(onSubmit)
                    Button(action: onSubmit) {
                        Image(systemName: "arrow.up").font(.system(size: 11, weight: .bold)).foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(empty ? Color.white.opacity(0.14) : Theme.accentFill))
                    }
                    .buttonStyle(.plain)
                    .disabled(empty)
                }
                .padding(.leading, 14).padding(.trailing, 6)
                .transition(.opacity.animation(.easeOut(duration: 0.18).delay(0.1)))
            } else {
                HStack(spacing: 5) {
                    Image(systemName: "keyboard").font(.system(size: 10, weight: .semibold))
                    Text("Type").font(.system(size: 11, weight: .medium))
                }
                .foregroundStyle(.white.opacity(0.85))
                .fixedSize()
                .transition(.opacity.animation(.easeOut(duration: 0.1)))
            }
        }
        .frame(width: pet.expanded ? Pet.barSize.width : 64, height: pet.expanded ? Pet.barSize.height : 24)
        .background(Capsule().fill(Theme.popup.opacity(0.94)))
        .overlay(Capsule().strokeBorder(.white.opacity(pet.expanded ? 0.22 : 0.14), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
        .contentShape(Capsule())
        .onTapGesture { if !pet.expanded { onExpand() } }
        .environment(\.colorScheme, .dark)
        .onChange(of: pet.expanded) { _, open in focused = open }
    }
}
