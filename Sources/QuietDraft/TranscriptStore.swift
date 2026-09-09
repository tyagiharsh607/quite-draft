import Foundation
import Combine

let debugLogPath = NSHomeDirectory() + "/quietdraft_debug.log"

func debugLog(_ message: String) {
    let line = "\(Date()) \(message)\n"
    if let data = line.data(using: .utf8) {
        if let handle = FileHandle(forWritingAtPath: debugLogPath) {
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        } else {
            try? data.write(to: URL(fileURLWithPath: debugLogPath))
        }
    }
}

@MainActor
final class TranscriptStore: ObservableObject {
    @Published var editableText: String = ""
    @Published var isSending: Bool = false
    @Published var statusMessage: String = ""
    @Published private(set) var history: [ChatMessage] = []

    var transcript: [ChatMessage] {
        history.filter { $0.role != .system }
    }

    private let stt: WhisperLocalProvider?
    private let audio = AudioCapture()
    private let llm: LLMProvider
    private var pollTimer: Timer?

    init() {
        let stt = WhisperLocalProvider(modelPath: Config.whisperModelPath)
        self.stt = stt
        self.llm = OpenAIProvider(apiKey: Config.openAIAPIKey, model: Config.openAIModel, reasoningEffort: Config.reasoningEffort)
        if stt == nil {
            statusMessage = "Failed to load Whisper model at \(Config.whisperModelPath)"
        }
        debugLog("[store] init, stt=\(stt != nil)")

        history.append(ChatMessage(
            role: .system,
            content: InterviewPrompt.systemMessage(resumeOrJD: Config.resumeOrJDContext)
        ))
    }

    func startListening() {
        debugLog("[store] startListening() called, stt=\(stt != nil)")
        guard let stt else { return }
        var sampleCount = 0
        audio.onSamples = { [weak stt] samples in
            sampleCount += samples.count
            if sampleCount % 16000 < samples.count { // log roughly once a second
                debugLog("[audio] +\(samples.count) samples (total \(sampleCount))")
            }
            stt?.appendAudio(samples)
        }
        audio.onError = { [weak self] error in
            debugLog("[audio] ERROR: \(error)")
            Task { @MainActor in
                self?.statusMessage = "Audio error: \(error.localizedDescription)"
            }
        }
        audio.onStatus = { [weak self] message in
            Task { @MainActor in
                self?.statusMessage = message
            }
        }
        Task {
            do {
                try await audio.start()
                statusMessage = "Listening…"
                debugLog("[audio] capture started OK")
            } catch {
                statusMessage = "Failed to start audio capture: \(error.localizedDescription)"
                debugLog("[audio] FAILED TO START: \(error)")
            }
        }
        // Periodically pull newly recognized text into the live buffer.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let stt = self.stt else { return }
                let new = WhisperText.sanitize(stt.drainPendingText())
                guard !new.isEmpty else { return }
                debugLog("[stt] recognized: \(new)")
                self.backgroundBuffer += (self.backgroundBuffer.isEmpty ? "" : " ") + new
            }
        }
    }

    /// Everything recognized since the last Submit/Clear, not yet shown in the editable box.
    private var backgroundBuffer: String = ""

    /// Freeze recognized speech into the editable box, including audio that
    /// has not yet reached a full Whisper chunk.
    func grab() {
        Task {
            await stt?.flushPendingAudio()
            let flushed = WhisperText.sanitize(stt?.drainPendingText() ?? "")
            if !flushed.isEmpty {
                backgroundBuffer += (backgroundBuffer.isEmpty ? "" : " ") + flushed
            }
            backgroundBuffer = WhisperText.sanitize(backgroundBuffer)
            debugLog("[store] grab() -> '\(backgroundBuffer)'")
            editableText = backgroundBuffer
        }
    }

    /// Wipe the background buffer without sending anything to the LLM.
    func clear() {
        backgroundBuffer = ""
        editableText = ""
        stt?.discardBufferedAudio()
    }

    /// Send the current editable text to the LLM, then clear the buffer.
    func submit() {
        let question = editableText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !isSending else { return }

        history.append(ChatMessage(role: .user, content: question))
        let historySnapshot = history
        history.append(ChatMessage(role: .assistant, content: ""))
        isSending = true
        debugLog("[store] submit() -> calling llm.answer, question='\(question)'")

        Task {
            do {
                let text = try await llm.answer(history: historySnapshot) { partial in
                    Task { @MainActor in
                        self.setLastAssistant(partial)
                    }
                }
                debugLog("[store] llm.answer returned")
                await MainActor.run {
                    self.setLastAssistant(text)
                    self.isSending = false
                }
            } catch {
                await MainActor.run {
                    self.setLastAssistant("Error: \(error.localizedDescription)")
                    self.isSending = false
                }
            }
        }

        backgroundBuffer = ""
        editableText = ""
    }

    private func setLastAssistant(_ text: String) {
        guard let index = history.indices.last, history[index].role == .assistant else { return }
        var copy = history
        copy[index].content = text
        history = copy
    }
}
