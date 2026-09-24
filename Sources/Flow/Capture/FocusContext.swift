import AppKit
import ApplicationServices

/// Where the user was when they pressed the hotkey. Captured on key-down so "paste this" goes to the
/// field they were in, not wherever focus ends up after Flow's overlay appears.
struct FocusContext {
    let app: NSRunningApplication?
    let appName: String
    let bundleId: String
    let element: AXUIElement?
    let role: String
    let isTextInput: Bool
    let selectedText: String
    let windowTitle: String

    static func capture() -> FocusContext {
        let app = NSWorkspace.shared.frontmostApplication
        var element: AXUIElement?
        var role = ""
        var selected = ""
        var window = ""
        var editable = false

        if AXIsProcessTrusted() {
            let system = AXUIElementCreateSystemWide()
            element = AX.element(system, kAXFocusedUIElementAttribute)
            if let el = element {
                role = AX.string(el, kAXRoleAttribute) ?? ""
                selected = AX.string(el, kAXSelectedTextAttribute) ?? ""
                var settable: DarwinBoolean = false
                if AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &settable) == .success { editable = settable.boolValue }
            }
            if let pid = app?.processIdentifier {
                let appEl = AXUIElementCreateApplication(pid)
                if let w = AX.element(appEl, kAXFocusedWindowAttribute) { window = AX.string(w, kAXTitleAttribute) ?? "" }
            }
        }
        let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXWebArea"]
        let isText = textRoles.contains(role) || (editable && role != "AXButton" && role != "AXCheckBox")
        return FocusContext(app: app, appName: app?.localizedName ?? "Unknown", bundleId: app?.bundleIdentifier ?? "",
                            element: element, role: role, isTextInput: isText, selectedText: selected, windowTitle: window)
    }
}

enum AX {
    static func element(_ el: AXUIElement, _ attr: String) -> AXUIElement? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success, let v,
              CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func string(_ el: AXUIElement, _ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, attr as CFString, &v) == .success else { return nil }
        return v as? String
    }

    static func children(_ el: AXUIElement) -> [AXUIElement] {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXChildrenAttribute as CFString, &v) == .success,
              let arr = v as? [AXUIElement] else { return [] }
        return arr
    }

    static func actions(_ el: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(el, &names) == .success, let arr = names as? [String] else { return [] }
        return arr
    }

    /// Breadth-first search of an app's windows for a pressable element whose label matches.
    static func findPressable(in pid: pid_t, label: String, limit: Int = 4000) -> AXUIElement? {
        let target = label.lowercased().trimmingCharacters(in: .whitespaces)
        let app = AXUIElementCreateApplication(pid)
        var queue: [AXUIElement] = []
        if let w = element(app, kAXFocusedWindowAttribute) { queue.append(w) }
        queue += children(app)
        var visited = 0
        var fuzzy: AXUIElement?
        while !queue.isEmpty && visited < limit {
            let el = queue.removeFirst()
            visited += 1
            let labels = [kAXTitleAttribute, kAXDescriptionAttribute, kAXHelpAttribute, "AXIdentifier"]
                .compactMap { string(el, $0)?.lowercased() }
                .filter { !$0.isEmpty }
            if !labels.isEmpty, actions(el).contains(kAXPressAction) {
                if labels.contains(target) { return el }
                if fuzzy == nil, labels.contains(where: { $0.contains(target) || target.contains($0) && $0.count > 2 }) { fuzzy = el }
            }
            queue += children(el)
        }
        return fuzzy
    }
}
