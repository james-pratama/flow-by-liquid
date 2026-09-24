import AppKit

if CLI.handles(CommandLine.arguments) {
    CLI.run(CommandLine.arguments)   // never returns
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    withExtendedLifetime(delegate) { app.run() }
}
