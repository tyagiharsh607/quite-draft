import AppKit
import ApplicationServices
import Foundation

enum BrowserPageError: Error, LocalizedError {
    case needsPermission(String)
    case javascriptOff(String)
    case needsAccessibility

    var errorDescription: String? {
        switch self {
        case .needsPermission(let app):
            return "Click Allow on “QuietDraft wants to control \(app)”. It only shows up in Automation after that."
        case .javascriptOff(let app):
            return "In \(app): View → Developer → Allow JavaScript from Apple Events, then fully quit \(app) (Cmd+Q) and Scan again."
        case .needsAccessibility:
            return "Click Allow on QuietDraft’s Accessibility prompt, then Scan again."
        }
    }
}

/// Reads the actual web page text from the browser. Screenshot OCR cannot see
/// Chrome's GPU-composited page — only the tab strip / bookmarks.
enum BrowserPage {
    private struct Target {
        let bundleID: String
        let appName: String
        let script: String
    }

    static func readVisible(bundleID: String) async throws -> String? {
        if let ax = try BrowserAX.readVisible(bundleID: bundleID) {
            debugLog("[scan] using accessibility text chars=\(ax.count)")
            return ax
        }

        let running = Set(
            NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier }
        )
        let targets = Self.targets.filter { $0.bundleID == bundleID && running.contains($0.bundleID) }
        guard !targets.isEmpty else { return nil }

        var permissionApp: String?
        var jsOffApp: String?
        var best = ""
        for target in targets {
            do {
                try await MainActor.run { try requestAutomation(for: target) }
            } catch {
                permissionApp = target.appName
                continue
            }
            let result = await MainActor.run { run(target) }
            debugLog("[scan] applescript \(target.appName) result=\(String(describing: result))")
            switch result {
            case .permissionDenied:
                permissionApp = target.appName
            case .javascriptOff:
                jsOffApp = target.appName
            case .text(let text):
                if text.count > best.count { best = text }
            case .empty:
                continue
            }
        }
        if best.count >= 40 {
            debugLog("[scan] browser text chars=\(best.count)")
            return cap(best)
        }
        if let jsOffApp {
            throw BrowserPageError.javascriptOff(jsOffApp)
        }
        if let permissionApp {
            throw BrowserPageError.needsPermission(permissionApp)
        }
        return best.isEmpty ? nil : cap(best)
    }

    private enum ScriptResult {
        case text(String)
        case empty
        case permissionDenied
        case javascriptOff
    }

    private static func run(_ target: Target) -> ScriptResult {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: target.script) else { return .empty }
        let result = script.executeAndReturnError(&error)
        if let error {
            let number = error[NSAppleScript.errorNumber] as? Int ?? 0
            let message = error[NSAppleScript.errorMessage] as? String ?? "\(error)"
            debugLog("[scan] applescript error \(number): \(message)")
            if number == -1743 {
                return .permissionDenied
            }
            if number == 12 || message.localizedCaseInsensitiveContains("Allow JavaScript from Apple Events")
                || message.localizedCaseInsensitiveContains("turned off") {
                return .javascriptOff
            }
            return .empty
        }
        let text = (result.stringValue ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? .empty : .text(text)
    }

    /// Registers QuietDraft in System Settings → Automation by asking for
    /// the real “control this app” prompt. Browsing that pane first is empty.
    private static func requestAutomation(for target: Target) throws {
        let descriptor = NSAppleEventDescriptor(bundleIdentifier: target.bundleID)
        guard let aeDesc = descriptor.aeDesc else { return }
        let status = AEDeterminePermissionToAutomateTarget(
            aeDesc,
            typeWildCard,
            typeWildCard,
            true
        )
        debugLog("[scan] automation \(target.bundleID) status=\(status)")
        if status == OSStatus(errAEEventNotPermitted) {
            throw BrowserPageError.needsPermission(target.appName)
        }
    }

    private static func cap(_ text: String) -> String {
        if text.count <= 12_000 { return text }
        let end = text.index(text.startIndex, offsetBy: 12_000)
        return String(text[..<end])
    }

    private static let js = "document.body.innerText"

    private static var targets: [Target] {
        // Chrome's verb is `execute <tab> javascript "..."` — not Safari's
        // `do JavaScript "..." in document`. The Safari-style `in` form compiles
        // as a get and returns -1723 even when JS-from-Apple-Events is on.
        let chromeJS = { (app: String) -> String in
            """
            tell application "\(app)"
              if (count of windows) is 0 then return ""
              execute (active tab of window 1) javascript "\(js)"
            end tell
            """
        }
        return [
            Target(bundleID: "com.google.Chrome", appName: "Google Chrome", script: chromeJS("Google Chrome")),
            Target(bundleID: "com.google.Chrome.canary", appName: "Google Chrome Canary", script: chromeJS("Google Chrome Canary")),
            Target(bundleID: "com.brave.Browser", appName: "Brave Browser", script: chromeJS("Brave Browser")),
            Target(bundleID: "com.microsoft.edgemac", appName: "Microsoft Edge", script: chromeJS("Microsoft Edge")),
            Target(bundleID: "company.thebrowser.Browser", appName: "Arc", script: chromeJS("Arc")),
            Target(
                bundleID: "com.apple.Safari",
                appName: "Safari",
                script: """
                tell application "Safari"
                  if (count of documents) is 0 then return ""
                  return do JavaScript "\(js)" in front document
                end tell
                """
            ),
        ]
    }
}
