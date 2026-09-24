import SwiftUI

/// Edit every instruction Flow gives its model. Changes save as you type and apply to the next command.
struct PromptsView: View {
    @State private var selection: Prompts.Key = .persona
    @State private var text = Prompts.text(.persona)
    @State private var customized: Set<Prompts.Key> = Set(Prompts.Key.allCases.filter(Prompts.isCustomized))
    @State private var warmTask: Task<Void, Never>?

    var body: some View {
        // Pin the page to the window's size so a long prompt scrolls inside the editor
        // instead of growing the page (and the window) to fit it.
        GeometryReader { geo in
            content(editorHeight: max(140, geo.size.height - 230))
                .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
    }

    private func content(editorHeight: CGFloat) -> some View {
        HStack(spacing: 0) {
            List(selection: Binding(get: { selection }, set: { if let k = $0 { switchTo(k) } })) {
                Section("Everyday") {
                    ForEach(Prompts.Key.allCases.filter { !$0.isAdvanced }) { row($0) }
                }
                Section("Advanced") {
                    ForEach(Prompts.Key.allCases.filter(\.isAdvanced)) { row($0) }
                }
            }
            .listStyle(.sidebar)
            .frame(width: 230)

            Divider()

            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    PageTitle(accent: selection.title, rest: "", size: 28)
                    Spacer()
                    Button("Reset to default") {
                        Prompts.reset(selection)
                        text = Prompts.text(selection)
                        refreshCustomized()
                        warmRouter()
                    }
                    .buttonStyle(.pillOutline)
                    .disabled(!customized.contains(selection))
                }
                Text(.init(selection.help)).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                TextEditor(text: $text)
                    .font(.system(.body, design: .monospaced))
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.hairline))
                    .frame(height: editorHeight)
                    .onChange(of: text) { _, new in
                        Prompts.set(selection, new)
                        refreshCustomized()
                        warmRouter()
                    }

                HStack {
                    Text(selection == .persona ? "Added to the start of the answering, meeting and email prompts."
                         : selection == .router ? "Sent on its own, without the personality." : "Sent after the personality prompt.")
                    Spacer()
                    Text("\(text.count) characters · saved automatically")
                }
                .font(.caption).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 24)
            .padding(.top, 36)
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    private func row(_ k: Prompts.Key) -> some View {
        HStack {
            Text(k.title)
            Spacer()
            if customized.contains(k) {
                Text("Edited").font(.caption2.weight(.semibold)).foregroundStyle(Color.accentColor)
            }
        }
        .tag(k)
    }

    private func switchTo(_ k: Prompts.Key) {
        selection = k
        text = Prompts.text(k)
    }

    private func refreshCustomized() {
        customized = Set(Prompts.Key.allCases.filter(Prompts.isCustomized))
    }

    /// The router prompt is cached by llama-server; re-warm it after edits so the next command stays fast.
    private func warmRouter() {
        guard selection == .persona || selection == .router else { return }
        warmTask?.cancel()
        warmTask = Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled else { return }
            await Router.shared.warmUp()
        }
    }
}
