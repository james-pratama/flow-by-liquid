import AppKit
import AVFoundation
import ApplicationServices
import EventKit

/// macOS privacy permissions Flow's tools depend on.
enum SystemPermission: String, CaseIterable, Identifiable {
    case microphone, inputMonitoring, accessibility, screenAudio, calendars, location
    var id: String { rawValue }

    var title: String {
        switch self {
        case .microphone: return "Microphone"
        case .inputMonitoring: return "Input Monitoring"
        case .accessibility: return "Accessibility"
        case .screenAudio: return "Screen & System Audio Recording"
        case .calendars: return "Calendars"
        case .location: return "Location"
        }
    }

    var why: String {
        switch self {
        case .microphone: return "Hear you while the hotkey is held, and in meetings"
        case .inputMonitoring: return "Detect your push-to-talk hotkey from any app"
        case .accessibility: return "Paste into the focused field and press buttons for you"
        case .screenAudio: return "Capture the other side of calls when transcribing meetings"
        case .calendars: return "Show your meetings and offer to record them when they start"
        case .location: return "Know which city you're in for weather, places and “near me” answers"
        }
    }

    var symbol: String {
        switch self {
        case .microphone: return "mic.fill"
        case .inputMonitoring: return "keyboard"
        case .accessibility: return "accessibility"
        case .screenAudio: return "speaker.wave.2.fill"
        case .calendars: return "calendar"
        case .location: return "location.fill"
        }
    }

    var isGranted: Bool {
        switch self {
        case .microphone: return AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        case .inputMonitoring: return CGPreflightListenEventAccess()
        case .accessibility: return AXIsProcessTrusted()
        case .screenAudio: return CGPreflightScreenCaptureAccess()
        case .calendars: return EKEventStore.authorizationStatus(for: .event) == .fullAccess
        case .location: return LocationService.shared.isAuthorized
        }
    }

    private var settingsAnchor: String {
        switch self {
        case .microphone: return "Privacy_Microphone"
        case .inputMonitoring: return "Privacy_ListenEvent"
        case .accessibility: return "Privacy_Accessibility"
        case .screenAudio: return "Privacy_ScreenCapture"
        case .calendars: return "Privacy_Calendars"
        case .location: return "Privacy_LocationServices"
        }
    }

    func openSettings() {
        // macOS 13+ System Settings deep link, with the legacy form as a fallback.
        let modern = URL(string: "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?\(settingsAnchor)")!
        let legacy = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(settingsAnchor)")!
        if !NSWorkspace.shared.open(modern) { NSWorkspace.shared.open(legacy) }
    }

    /// Shows the system prompt where macOS allows one; otherwise opens the right Settings pane.
    @MainActor
    func request() async {
        switch self {
        case .microphone:
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .audio)
            } else { openSettings() }
        case .inputMonitoring:
            if !CGRequestListenEventAccess() { openSettings() }
        case .accessibility:
            let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            if !AXIsProcessTrustedWithOptions(opts) { openSettings() }
        case .screenAudio:
            if !CGRequestScreenCaptureAccess() { openSettings() }
        case .calendars:
            if EKEventStore.authorizationStatus(for: .event) == .notDetermined {
                _ = try? await CalendarWatcher.shared.eventStore.requestFullAccessToEvents()
                CalendarWatcher.shared.authorizationChanged()
            } else { openSettings() }
        case .location:
            LocationService.shared.request()
        }
    }
}
