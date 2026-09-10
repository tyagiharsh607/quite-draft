import ApplicationServices
import AppKit
import Foundation

/// Reads on-screen browser *page* text via Accessibility + the active tab title.
/// Does not dump tab strips, bookmarks, or the address bar.
enum BrowserAX {
    static func readVisible(bundleID: String) throws -> String? {
        if !AXIsProcessTrustedWithOptions([
            kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true
        ] as CFDictionary) {
            throw BrowserPageError.needsAccessibility
        }

        let title = bundleID.lowercased().contains("chrome") ? chromeTabTitle() : nil
        var page = ""

        for pid in browserPIDs(matching: bundleID) {
            let text = readPage(pid: pid)
            debugLog("[scan] ax pid=\(pid) page chars=\(text.count)")
            if text.count > page.count { page = text }
        }

        var parts: [String] = []
        // Tab title is useful when the page AX tree is empty (YouTube).
        // Skip it once we already have real page body — it is chrome, not the question.
        if let title, page.count < 400, !page.contains(title) {
            parts.append(title)
        }
        if !page.isEmpty { parts.append(page) }

        let combined = uniqued(parts.flatMap { $0.components(separatedBy: "\n") })
            .filter { !isChromeUI($0) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return combined.count >= 20 ? cap(combined) : nil
    }

    /// Active tab title only — no URL, no other tabs. Does not need JS-from-Apple-Events.
    private static func chromeTabTitle() -> String? {
        let text = runAppleScript("""
            tell application "Google Chrome"
              if (count of windows) is 0 then return ""
              return title of active tab of window 1
            end tell
            """)
        guard let text, !isChromeUI(text) else { return nil }
        debugLog("[scan] chrome tab title chars=\(text.count)")
        return text
    }

    private static func browserPIDs(matching bundleID: String) -> [pid_t] {
        let apps = NSWorkspace.shared.runningApplications.filter { app in
            guard let bid = app.bundleIdentifier else { return false }
            if bid == bundleID { return true }
            if bundleID.hasPrefix("com.google.Chrome"), bid.hasPrefix("com.google.Chrome") { return true }
            return false
        }
        return apps.map(\.processIdentifier)
    }

    private static func runAppleScript(_ source: String) -> String? {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&error)
        if let error {
            debugLog("[scan] ax applescript error \(error[NSAppleScript.errorNumber] ?? 0): \(error[NSAppleScript.errorMessage] ?? "")")
            return nil
        }
        let text = result.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (text?.isEmpty == false) ? text : nil
    }

    /// Page document only — never the window chrome.
    private static func readPage(pid: pid_t) -> String {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)

        var best = ""
        for window in focusedThenAllWindows(app) {
            let webTexts = allWebAreas(window).map { web -> String in
                var lines: [String] = []
                collectPage(web, into: &lines, depth: 0)
                return uniqued(lines).filter { !isChromeUI($0) }.joined(separator: "\n")
            }
            if let richest = webTexts.max(by: { $0.count < $1.count }), richest.count > best.count {
                best = richest
            }
        }
        return best
    }

    private static func focusedThenAllWindows(_ app: AXUIElement) -> [AXUIElement] {
        var ordered: [AXUIElement] = []
        var focused: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &focused) == .success,
           let focused {
            ordered.append(asElement(focused))
        }
        for window in children(of: app, attribute: kAXWindowsAttribute as CFString) {
            if !ordered.contains(where: { CFEqual($0, window) }) {
                ordered.append(window)
            }
        }
        debugLog("[scan] ax windows=\(ordered.count)")
        return ordered
    }

    private static func allWebAreas(_ root: AXUIElement) -> [AXUIElement] {
        var found: [AXUIElement] = []
        _ = walk(root, depth: 0) { el, role in
            if role == "AXWebArea" || role == "AXDocument" { found.append(el) }
            return true
        }
        return found
    }

    private static func asElement(_ ref: CFTypeRef) -> AXUIElement {
        unsafeBitCast(ref, to: AXUIElement.self)
    }

    @discardableResult
    private static func walk(_ element: AXUIElement, depth: Int, visit: (AXUIElement, String) -> Bool) -> Bool {
        guard depth < 60 else { return true }
        guard visit(element, role(of: element)) else { return false }
        for child in children(of: element) {
            if !walk(child, depth: depth + 1, visit: visit) { return false }
        }
        return true
    }

    private static func children(of element: AXUIElement, attribute: CFString = kAXChildrenAttribute as CFString) -> [AXUIElement] {
        var ref: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, attribute, &ref) == .success, let array = ref as? NSArray, array.count > 0 {
            return (0..<array.count).map { asElement(array[$0] as CFTypeRef) }
        }
        var visible: CFTypeRef?
        if attribute as String == kAXChildrenAttribute as String,
           AXUIElementCopyAttributeValue(element, kAXVisibleChildrenAttribute as CFString, &visible) == .success,
           let array = visible as? NSArray {
            return (0..<array.count).map { asElement(array[$0] as CFTypeRef) }
        }
        return []
    }

    private static func collectPage(_ element: AXUIElement, into lines: inout [String], depth: Int) {
        guard depth < 60 else { return }
        let r = role(of: element)
        // Chrome still nests toolbar/tab junk under some web areas.
        let skipRoles = [
            "AXToolbar", "AXTabGroup", "AXTab", "AXMenuBar", "AXMenu",
            "AXMenuButton", "AXPopUpButton",
        ]
        if skipRoles.contains(r) { return }

        let allowed = [
            "AXStaticText", "AXTextArea", "AXHeading", "AXLink",
            "AXWebArea", "AXDocument", "AXGroup", "AXButton",
            "AXRadioButton", "AXCheckBox", "AXList", "AXListItem",
        ]
        if allowed.contains(r) {
            if let value = stringAttr(element, kAXValueAttribute as CFString) { append(value, to: &lines) }
            if let title = stringAttr(element, kAXTitleAttribute as CFString) { append(title, to: &lines) }
        }

        for child in children(of: element) {
            collectPage(child, into: &lines, depth: depth + 1)
        }
    }

    private static func role(of element: AXUIElement) -> String {
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        return roleRef as? String ?? ""
    }

    private static func stringAttr(_ element: AXUIElement, _ name: CFString) -> String? {
        var ref: CFTypeRef?
        AXUIElementCopyAttributeValue(element, name, &ref)
        let text = (ref as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let text, text.count > 1 else { return nil }
        return text
    }

    private static func append(_ text: String, to lines: inout [String]) {
        if lines.last != text { lines.append(text) }
    }

    private static func uniqued(_ lines: [String]) -> [String] {
        var seen = Set<String>()
        return lines.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    private static func isChromeUI(_ text: String) -> Bool {
        let lower = text.lowercased()
        let banned = [
            "address and search bar", "google chrome", "new tab", "close",
            "back", "forward", "reload", "extensions", "bookmark this tab",
            "bookmarks", "bookmark manager", "bookmarks bar",
            "customize and control google chrome", "this tab is playing audio",
            "search google or type a url", "tab",
        ]
        if banned.contains(lower) { return true }
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") { return true }
        if lower.contains("youtube.com/watch") && !lower.contains(" ") { return true }
        return false
    }

    private static func cap(_ text: String) -> String {
        if text.count <= 12_000 { return text }
        let end = text.index(text.startIndex, offsetBy: 12_000)
        return String(text[..<end])
    }
}
