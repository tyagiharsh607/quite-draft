import Foundation

/// Abstraction over speech-to-text so the local Whisper engine can later
/// be swapped for a cloud streaming provider without touching call sites.
protocol STTProvider: AnyObject {
    /// Feed newly captured mono 16kHz Float32 PCM samples.
    func appendAudio(_ samples: [Float])

    /// Text recognized so far that hasn't been consumed yet.
    var pendingText: String { get }

    /// Consume (and clear) whatever has been recognized so far.
    func drainPendingText() -> String

    /// Transcribe any audio that has not reached a full chunk yet, so Grab
    /// includes speech up to this moment instead of lagging by a few seconds.
    func flushPendingAudio() async
}
