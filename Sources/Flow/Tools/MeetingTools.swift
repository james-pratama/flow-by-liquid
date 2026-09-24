import Foundation

struct StartMeetingTool: FlowTool {
    let name = "start_meeting"
    let title = "Transcribe meetings"
    let summary = "Records your mic and the call's audio, then writes notes and pulls out your commitments."
    let symbol = "waveform"
    let risk = ToolRisk.reversible
    let permissions: [SystemPermission] = [.microphone]
    let defaultPolicy = ToolPolicy.always
    let args: [(String, OJ)] = [("title", .str)]

    func describe(_ a: Args) -> String { "Start transcribing \(a.string("title").isEmpty ? "this meeting" : a.string("title"))" }

    func run(_ a: Args, _ ctx: ToolContext) async throws -> ToolOutcome {
        let recorder = await MeetingRecorder.shared
        if let active = await recorder.active { return ToolOutcome(message: "Already recording", detail: active.title, style: .info) }
        var title = a.string("title")
        if title.isEmpty { title = await CalendarWatcher.shared.currentEventTitle() ?? "Meeting" }
        let e = try await recorder.start(title: title)
        let note = await recorder.capturingSystemAudio ? "Mic + call audio" : "Mic only — allow Screen & System Audio Recording to capture the other side"
        return ToolOutcome(message: "Transcribing “\(title)”", detail: note, entry: e)
    }
}

struct StopMeetingTool: FlowTool {
    let name = "stop_meeting"
    let title = "Stop meeting transcription"
    let summary = "Stops the current meeting transcription and writes notes."
    let symbol = "stop.circle"
    let risk = ToolRisk.reversible
    let permissions: [SystemPermission] = []
    let defaultPolicy = ToolPolicy.always
    let args: [(String, OJ)] = []

    func describe(_ a: Args) -> String { "Stop transcribing" }

    func run(_ a: Args, _ ctx: ToolContext) async throws -> ToolOutcome {
        guard let e = await MeetingRecorder.shared.stop() else {
            return ToolOutcome(message: "No meeting is being recorded", style: .info)
        }
        return ToolOutcome(message: "Stopped recording", detail: "Writing notes for “\(e.title)”…", entry: e)
    }
}
