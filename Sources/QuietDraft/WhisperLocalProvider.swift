import Foundation
import CWhisper

/// Local, on-device STT backed by whisper.cpp. Runs Metal-accelerated
/// inference in fixed-size chunks on a background queue so it never blocks
/// the audio-capture callback.
final class WhisperLocalProvider: STTProvider {
    private let ctx: OpaquePointer
    private let queue = DispatchQueue(label: "whisper.inference")
    private let lock = NSLock()

    // Audio waiting to be transcribed (16kHz mono Float32).
    private var incoming: [Float] = []
    // Text already recognized, not yet drained by the UI.
    private var recognized: String = ""

    /// Re-run inference once at least this many new samples have queued up.
    private let chunkSamples: Int = 16_000 // ~1s @ 16kHz
    /// Ignore leftover audio shorter than this on Grab (Whisper hallucinates on tiny clips).
    private let minFlushSamples: Int = 16_000 / 4 // ~250ms

    init?(modelPath: String) {
        ggml_backend_load_all()
        var cparams = whisper_context_default_params()
        cparams.use_gpu = true
        guard let ctx = whisper_init_from_file_with_params(modelPath, cparams) else {
            return nil
        }
        self.ctx = ctx
    }

    deinit {
        whisper_free(ctx)
    }

    func appendAudio(_ samples: [Float]) {
        queue.async { [weak self] in
            guard let self else { return }
            self.incoming.append(contentsOf: samples)
            if self.incoming.count >= self.chunkSamples {
                self.transcribeQueuedAudio()
            }
        }
    }

    var pendingText: String {
        lock.lock(); defer { lock.unlock() }
        return recognized
    }

    func drainPendingText() -> String {
        lock.lock(); defer { lock.unlock() }
        let text = recognized
        recognized = ""
        return text
    }

    /// Flush the buffer even if it hasn't reached a full chunk yet (call on Clear).
    func discardBufferedAudio() {
        queue.async { [weak self] in
            self?.incoming.removeAll()
        }
    }

    func flushPendingAudio() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { [weak self] in
                defer { continuation.resume() }
                guard let self, self.incoming.count >= self.minFlushSamples else { return }
                self.transcribeQueuedAudio()
            }
        }
    }

    private func transcribeQueuedAudio() {
        let samples = incoming
        incoming.removeAll()

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_progress = false
        params.print_realtime = false
        params.print_special = false
        params.translate = false
        params.no_context = true
        params.single_segment = false
        params.language = NSString(string: "en").utf8String
        params.n_threads = Int32(max(1, ProcessInfo.processInfo.activeProcessorCount - 1))

        let result = samples.withUnsafeBufferPointer { buf -> String in
            guard whisper_full(ctx, params, buf.baseAddress, Int32(buf.count)) == 0 else {
                return ""
            }
            var text = ""
            let n = whisper_full_n_segments(ctx)
            for i in 0..<n {
                if let cstr = whisper_full_get_segment_text(ctx, i) {
                    text += String(cString: cstr)
                }
            }
            return text.trimmingCharacters(in: .whitespaces)
        }

        let cleaned = WhisperText.sanitize(result)
        guard !cleaned.isEmpty else { return }
        lock.lock()
        if recognized.isEmpty {
            recognized = cleaned
        } else {
            recognized += " " + cleaned
        }
        lock.unlock()
    }
}

enum WhisperText {
    /// Whisper emits this token for silence; it is not real speech.
    static func sanitize(_ text: String) -> String {
        text.replacingOccurrences(
            of: #"\[BLANK_AUDIO\]"#,
            with: " ",
            options: [.regularExpression, .caseInsensitive]
        )
        .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
