import SwiftUI
import AppKit

/// Sets NSWindow.sharingType = .none on the enclosing window, which excludes
/// it from screen recording/capture APIs (Meet, Zoom, OBS, etc.) system-wide,
/// while keeping it fully visible on this Mac's own display.
private struct HiddenFromCaptureModifier: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            view.window?.sharingType = .none
        }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        nsView.window?.sharingType = .none
    }
}

extension View {
    func hiddenFromScreenCapture() -> some View {
        background(HiddenFromCaptureModifier())
    }
}

/// Overlay panel that can still take keyboard focus (TextEditor / buttons)
/// while remaining above other apps.
final class OverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = TranscriptStore()
    private var panel: OverlayPanel?
    private var tokens: [NSObjectProtocol] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let panel = OverlayPanel(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 480),
            styleMask: [.titled, .closable, .resizable, .miniaturizable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "InterviewAssist"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.sharingType = .none
        panel.isOpaque = false
        panel.alphaValue = 0.85
        panel.contentView = NSHostingView(rootView:
            ContentView()
                .environmentObject(store)
                .hiddenFromScreenCapture()
        )
        panel.center()
        self.panel = panel
        pinPanel()

        for window in NSApp.windows where window !== panel {
            window.orderOut(nil)
        }

        let center = NotificationCenter.default
        tokens.append(center.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.pinPanel()
            }
        })
        tokens.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.pinPanel()
            }
        })
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        pinPanel()
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    private func pinPanel() {
        guard let panel else { return }
        panel.hidesOnDeactivate = false
        panel.level = .popUpMenu
        panel.sharingType = .none
        panel.orderFrontRegardless()
    }
}

@main
struct InterviewAssistApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // Placeholder scene only. The real UI is the always-on-top NSPanel
        // created in AppDelegate — WindowGroup cannot stay above other apps.
        Settings {
            EmptyView()
        }
    }
}
