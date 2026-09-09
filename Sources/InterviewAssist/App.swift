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

@main
struct InterviewAssistApp: App {
    @StateObject private var store = TranscriptStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(store)
                .hiddenFromScreenCapture()
        }
    }
}
