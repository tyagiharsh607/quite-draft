import AppKit
import CoreGraphics
import CoreImage
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit
import Vision

enum ScreenOCRError: Error, LocalizedError {
    case noDisplay
    case noImage
    case noText

    var errorDescription: String? {
        switch self {
        case .noDisplay:
            return "No display available to scan"
        case .noImage:
            return "Could not capture the screen"
        case .noText:
            return "No readable question found on screen"
        }
    }
}

/// Park the overlay off-screen during a scan.
/// `sharingType = .none` punches a hole in ScreenCaptureKit (Chrome tabs stay,
/// the page under the overlay does not). `orderOut` would quit the app.
enum OverlayChrome {
    @MainActor static weak var panel: OverlayPanel?
    static var isHiding = false
    static var parkedDisplayID: CGDirectDisplayID?

    private struct Snapshot {
        let panel: OverlayPanel
        let frame: NSRect
        let alpha: CGFloat
    }

    static func withHidden<T>(_ work: () async throws -> T) async throws -> T {
        let snapshot = await MainActor.run { () -> Snapshot? in
            guard let panel else { return nil }
            isHiding = true
            let screen = panel.screen ?? NSScreen.main
            parkedDisplayID = screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            let saved = Snapshot(panel: panel, frame: panel.frame, alpha: panel.alphaValue)
            panel.ignoresMouseEvents = true
            panel.setFrameOrigin(NSPoint(x: -12_000, y: -12_000))
            return saved
        }
        try await Task.sleep(nanoseconds: 250_000_000)
        do {
            let result = try await work()
            await restore(snapshot)
            return result
        } catch {
            await restore(snapshot)
            throw error
        }
    }

    private static func restore(_ snapshot: Snapshot?) async {
        await MainActor.run {
            if let snapshot {
                snapshot.panel.setFrame(snapshot.frame, display: true)
                snapshot.panel.alphaValue = snapshot.alpha
                snapshot.panel.ignoresMouseEvents = false
                snapshot.panel.level = .popUpMenu
                snapshot.panel.sharingType = .none
                snapshot.panel.orderFrontRegardless()
            }
            isHiding = false
            parkedDisplayID = nil
        }
    }
}

enum ScreenOCR {
    static func readQuestion() async throws -> String {
        try await OverlayChrome.withHidden {
            let images = try await captureDisplays()
            var chunks: [String] = []
            for image in images {
                debugLog("[scan] image \(image.width)x\(image.height)")
                let lines = try await recognize(image)
                debugLog("[scan] ocr lines=\(lines.count)")
                let text = extractQuestion(from: lines)
                if !text.isEmpty { chunks.append(text) }
            }
            let question = chunks.joined(separator: "\n\n")
            guard !question.isEmpty else { throw ScreenOCRError.noText }
            debugLog("[scan] extracted \(question.count) chars")
            return question
        }
    }

    private static func captureDisplays() async throws -> [CGImage] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard !content.displays.isEmpty else { throw ScreenOCRError.noDisplay }

        let mine = (Bundle.main.bundleIdentifier ?? "com.local.quietdraft").lowercased()
        let myWindowNumber = await MainActor.run { OverlayChrome.panel?.windowNumber ?? 0 }
        let excludedWindows = content.windows.filter { window in
            let bid = (window.owningApplication?.bundleIdentifier ?? "").lowercased()
            if bid == mine || bid.contains("quietdraft") { return true }
            if window.windowID == CGWindowID(myWindowNumber) { return true }
            if (window.title ?? "").localizedCaseInsensitiveContains("QuietDraft") { return true }
            return false
        }

        let preferredID: CGDirectDisplayID?
        if let parked = OverlayChrome.parkedDisplayID {
            preferredID = parked
        } else {
            preferredID = await MainActor.run { () -> CGDirectDisplayID? in
                let screen = OverlayChrome.panel?.screen ?? NSScreen.main
                return screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            }
        }
        var images: [CGImage] = []
        var lastError: Error?

        let skipBundles = [
            "com.apple.dock", "com.apple.controlcenter", "com.apple.notificationcenterui",
            "com.apple.wallpaper", "com.apple.windowmanager", "com.apple.loginwindow",
            "com.apple.finder"
        ]
        let browserBundles = ["chrome", "safari", "brave", "edge", "firefox", "arc"]
        let windowCandidates = content.windows
            .filter { window in
                guard window.isOnScreen else { return false }
                let bid = (window.owningApplication?.bundleIdentifier ?? "").lowercased()
                if bid.contains("quietdraft") || window.windowID == CGWindowID(myWindowNumber) { return false }
                if skipBundles.contains(where: { bid.hasPrefix($0) || bid.contains($0) }) { return false }
                let frame = window.frame
                return frame.width > 400 && frame.height > 300
            }
            .sorted { a, b in
                let ab = (a.owningApplication?.bundleIdentifier ?? "").lowercased()
                let bb = (b.owningApplication?.bundleIdentifier ?? "").lowercased()
                let aBrowser = browserBundles.contains(where: { ab.contains($0) })
                let bBrowser = browserBundles.contains(where: { bb.contains($0) })
                if aBrowser != bBrowser { return aBrowser }
                return (a.frame.width * a.frame.height) > (b.frame.width * b.frame.height)
            }
        for window in windowCandidates.prefix(2) {
            do {
                if let image = try await capture(window: window) {
                    images.append(image)
                    saveDebug(image)
                }
            } catch {
                lastError = error
                debugLog("[scan] window \(window.windowID) \(window.owningApplication?.bundleIdentifier ?? "") failed: \(error)")
            }
        }

        let displays = content.displays.sorted { a, b in
            (a.displayID == preferredID ? 0 : 1) < (b.displayID == preferredID ? 0 : 1)
        }
        for display in displays.prefix(1) {
            do {
                if let image = try await capture(display: display, excludingWindows: excludedWindows) {
                    images.append(image)
                    saveDebug(image)
                }
            } catch {
                lastError = error
                debugLog("[scan] display \(display.displayID) failed: \(error)")
            }
        }
        if images.isEmpty {
            throw lastError ?? ScreenOCRError.noImage
        }
        return images
    }

    private static func capture(display: SCDisplay, excludingWindows: [SCWindow]) async throws -> CGImage? {
        let filter = SCContentFilter(display: display, excludingWindows: excludingWindows)
        let config = SCStreamConfiguration()
        config.capturesAudio = false
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 3
        let size = pixelSize(for: filter, display: display)
        config.width = size.width
        config.height = size.height
        debugLog("[scan] capture display=\(display.displayID) \(size.width)x\(size.height) excludeWindows=\(excludingWindows.count)")
        return try await grabFrame(filter: filter, configuration: config)
    }

    private static func capture(window: SCWindow) async throws -> CGImage? {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        config.capturesAudio = false
        config.showsCursor = false
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 3
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        config.width = max(2, Int((window.frame.width * scale).rounded()))
        config.height = max(2, Int((window.frame.height * scale).rounded()))
        debugLog("[scan] capture window=\(window.owningApplication?.applicationName ?? "?") \(config.width)x\(config.height)")
        return try await grabFrame(filter: filter, configuration: config)
    }

    private static func grabFrame(filter: SCContentFilter, configuration: SCStreamConfiguration) async throws -> CGImage {
        if #available(macOS 14.0, *) {
            do {
                let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
                if image.width > 32, image.height > 32 { return image }
            } catch {
                debugLog("[scan] ScreenshotManager failed: \(error)")
            }
        }
        return try await StreamFrameGrabber.grab(filter: filter, configuration: configuration)
    }

    private static func saveDebug(_ image: CGImage) {
        let url = URL(fileURLWithPath: NSHomeDirectory() + "/quietdraft_last_scan.png")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
        debugLog("[scan] wrote \(url.path)")
    }

    private static func pixelSize(for filter: SCContentFilter, display: SCDisplay) -> (width: Int, height: Int) {
        if #available(macOS 14.0, *) {
            let rect = filter.contentRect
            let scale = CGFloat(filter.pointPixelScale)
            if rect.width > 1, rect.height > 1, scale > 0 {
                return (max(2, Int((rect.width * scale).rounded())), max(2, Int((rect.height * scale).rounded())))
            }
        }
        let screenScale = NSScreen.screens.first { screen in
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            return number == display.displayID
        }?.backingScaleFactor ?? 2
        if abs(CGFloat(display.width) - display.frame.width) < 2 {
            return (
                max(2, Int((CGFloat(display.width) * screenScale).rounded())),
                max(2, Int((CGFloat(display.height) * screenScale).rounded()))
            )
        }
        return (max(2, display.width), max(2, display.height))
    }

    private static func recognize(_ image: CGImage) async throws -> [OCRLine] {
        try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            func resumeOnce(_ result: Result<[OCRLine], Error>) {
                guard !resumed else { return }
                resumed = true
                continuation.resume(with: result)
            }
            let request = VNRecognizeTextRequest { request, error in
                if let error {
                    resumeOnce(.failure(error))
                    return
                }
                let observations = (request.results as? [VNRecognizedTextObservation]) ?? []
                let lines: [OCRLine] = observations.compactMap { observation in
                    guard let candidate = observation.topCandidates(1).first else { return nil }
                    return OCRLine(
                        text: candidate.string.trimmingCharacters(in: .whitespacesAndNewlines),
                        box: observation.boundingBox,
                        confidence: candidate.confidence
                    )
                }.filter { !$0.text.isEmpty }
                resumeOnce(.success(lines))
            }
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            if #available(macOS 14.0, *) {
                request.automaticallyDetectsLanguage = true
            } else {
                request.recognitionLanguages = ["en-US"]
            }
            do {
                try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            } catch {
                resumeOnce(.failure(error))
            }
        }
    }

    private static func extractQuestion(from raw: [OCRLine]) -> String {
        let lines = mergeIntoReadingOrder(raw.filter { line in
            line.confidence >= 0.2 && !isOurOverlay(line.text)
        })
        guard !lines.isEmpty else { return "" }
        return cap(lines.map(\.text).joined(separator: "\n"))
    }

    private static func mergeIntoReadingOrder(_ lines: [OCRLine]) -> [OCRLine] {
        let sorted = lines.sorted {
            if abs($0.box.midY - $1.box.midY) > 0.012 {
                return $0.box.midY > $1.box.midY
            }
            return $0.box.minX < $1.box.minX
        }
        var merged: [OCRLine] = []
        for line in sorted {
            if var last = merged.last, abs(last.box.midY - line.box.midY) <= 0.012 {
                last.text += " " + line.text
                last.box = last.box.union(line.box)
                last.confidence = min(last.confidence, line.confidence)
                merged[merged.count - 1] = last
            } else {
                merged.append(line)
            }
        }
        return merged
    }

    private static func isOurOverlay(_ text: String) -> Bool {
        let lower = text.lowercased()
        let banned = [
            "quietdraft", "listening…", "listening...",
            "conversation will show up here"
        ]
        if banned.contains(where: { lower.contains($0) }) { return true }
        if lower == "grab" || lower == "clear" || lower == "submit" || lower == "scan screen" { return true }
        return false
    }

    private static func cap(_ text: String) -> String {
        let trimmed = text
            .replacingOccurrences(of: "[ \t]+", with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= 12_000 { return trimmed }
        let end = trimmed.index(trimmed.startIndex, offsetBy: 12_000)
        return String(trimmed[..<end])
    }
}

private struct OCRLine {
    var text: String
    var box: CGRect
    var confidence: Float
}

/// One video frame from ScreenCaptureKit. More reliable for GPU-composited
/// windows (Chrome) than a still screenshot while an audio stream is around.
private final class StreamFrameGrabber: NSObject, SCStreamOutput, SCStreamDelegate {
    private var continuation: CheckedContinuation<CGImage, Error>?
    private var stream: SCStream?
    private var resumed = false
    private let lock = NSLock()

    static func grab(filter: SCContentFilter, configuration: SCStreamConfiguration) async throws -> CGImage {
        let grabber = StreamFrameGrabber()
        return try await grabber.grab(filter: filter, configuration: configuration)
    }

    private func grab(filter: SCContentFilter, configuration: SCStreamConfiguration) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
            self.stream = stream
            do {
                try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "scan.frame"))
            } catch {
                finish(.failure(error))
                return
            }
            stream.startCapture { [weak self] error in
                if let error { self?.finish(.failure(error)) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 3.0) { [weak self] in
                self?.finish(.failure(ScreenOCRError.noImage))
            }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, let image = Self.cgImage(from: sampleBuffer) else { return }
        finish(.success(image))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        finish(.failure(error))
    }

    private func finish(_ result: Result<CGImage, Error>) {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return }
        resumed = true
        let stream = self.stream
        self.stream = nil
        continuation?.resume(with: result)
        continuation = nil
        Task { try? await stream?.stopCapture() }
    }

    private static func cgImage(from sampleBuffer: CMSampleBuffer) -> CGImage? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        return CIContext(options: [.useSoftwareRenderer: false]).createCGImage(ci, from: ci.extent)
    }
}
