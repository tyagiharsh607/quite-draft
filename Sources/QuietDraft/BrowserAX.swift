import ApplicationServices
import AppKit
import Foundation

/// Reads on-screen browser text via Accessibility + Chrome AppleScript
/// properties that do not need “Allow JavaScript from Apple Events”.
enum BrowserAX {
    static func readVisible() throws -> String? {
        if !AXIsProcessTrustedWithOptions([
            kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true
        ] as CFDictionary) {
            throw BrowserPageError.needsAccessibility
        }

        var chunks: [String] = []

        if let meta = chromeTabMeta(), !meta.isEmpty {
            debugLog("[scan] chrome tab meta chars=\(meta.count)")
            chunks.append(meta)
        }

        if let sys = systemEventsTexts(), !sys.isEmpty {
            debugLog("[scan] system events chars=\(sys.count)")
            chunks.append(sys)
        }

        let browsers = [
            "com.google.Chrome",
            "com.google.Chrome.canary",
            "com.brave.Browser",
            "com.microsoft.edgemac",
            "company.thebrowser.Browser",
            "com.apple.Safari",
        ]
        for bundle in browsers {
            guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundle }) else {
                continue
            }
            let text = read(pid: app.processIdentifier)
            debugLog("[scan] ax \(bundle) chars=\(text.count)")
            if !text.isEmpty { chunks.append(text) }
        }

        let combined = uniqued(chunks.flatMap { $0.components(separatedBy: "\n") })
            .filter { !isChromeUI($0) }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return combined.count >= 20 ? cap(combined) : nil
    }

    /// Title and URL — Chrome allows this without the JavaScript-from-Apple-Events flag.
    private static func chromeTabMeta() -> String? {
        runAppleScript("""
            tell application "Google Chrome"
              if (count of windows) is 0 then return ""
              set t to title of active tab of window 1
              set u to URL of active tab of window 1
              return t & linefeed & u
            end tell
            """)
    }

    private static func systemEventsTexts() -> String? {
        runAppleScript("""
            tell application "System Events"
              if not (exists process "Google Chrome") then return ""
              tell process "Google Chrome"
                if (count of windows) is 0 then return ""
                tell window 1
                  set collected to {}
                  try
                    set collected to collected & (value of every static text)
                  end try
                  try
                    set collected to collected & (name of every static text)
                  end try
                  try
                    set collected to collected & (value of every text field)
                  end try
                end tell
                set AppleScript's text item delimiters to linefeed
                return collected as text
              end tell
            end tell
            """)
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

    private static func read(pid: pid_t) -> String {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(app, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        Thread.sleep(forTimeInterval: 0.6)

        var best = ""
        let windows = children(of: app, attribute: kAXWindowsAttribute as CFString)
        debugLog("[scan] ax windows=\(windows.count)")
        for window in windows {
            logTopRoles(window)
            let webTexts = allWebAreas(window).map { web -> String in
                var lines: [String] = []
                collect(web, into: &lines, depth: 0, includeFields: false)
                return uniqued(lines).filter { !isChromeUI($0) }.joined(separator: "\n")
            }
            if let richest = webTexts.max(by: { $0.count < $1.count }), richest.count > best.count {
                best = richest
            }
            var windowLines: [String] = []
            collect(window, into: &windowLines, depth: 0, includeFields: false)
            let windowText = uniqued(windowLines).filter { !isChromeUI($0) }.joined(separator: "\n")
            if windowText.count > best.count { best = windowText }
        }
        return best
    }

    private static func logTopRoles(_ window: AXUIElement) {
        let kids = children(of: window)
        let roles = kids.prefix(12).map { role(of: $0) }.joined(separator: ",")
        debugLog("[scan] ax window children=\(kids.count) roles=\(roles)")
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

    private static func collect(_ element: AXUIElement, into lines: inout [String], depth: Int, includeFields: Bool) {
        guard depth < 60 else { return }
        let r = role(of: element)
        let skipRoles = ["AXToolbar", "AXTabGroup", "AXMenuBar", "AXMenu"]
        if skipRoles.contains(r) { return }

        let allowed = ["AXStaticText", "AXTextArea", "AXHeading", "AXLink", "AXWebArea", "AXDocument", "AXGroup"]
        let fields = includeFields ? ["AXTextField"] : []
        if (allowed + fields).contains(r) {
            if r == "AXTextField", let desc = stringAttr(element, kAXDescriptionAttribute as CFString), isChromeUI(desc) {
                // skip omnibox
            } else {
                if let value = stringAttr(element, kAXValueAttribute as CFString) { append(value, to: &lines) }
                if let title = stringAttr(element, kAXTitleAttribute as CFString) { append(title, to: &lines) }
                if r != "AXTextField", let desc = stringAttr(element, kAXDescriptionAttribute as CFString) {
                    append(desc, to: &lines)
                }
            }
        }

        for child in children(of: element) {
            collect(child, into: &lines, depth: depth + 1, includeFields: includeFields)
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
            "customize and control google chrome", "this tab is playing audio",
            "search google or type a url",
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
