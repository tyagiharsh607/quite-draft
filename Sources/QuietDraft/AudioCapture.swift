import Foundation
import ScreenCaptureKit
import AVFoundation
import CoreGraphics

/// Captures system OUTPUT audio only (what the interviewer's voice sounds
/// like coming out of your speakers/headphones via the call app) using
/// ScreenCaptureKit. Never touches the microphone.
final class AudioCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    private var stream: SCStream?
    private var converter: AVAudioConverter?
    private let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                              sampleRate: 16_000,
                                              channels: 1,
                                              interleaved: false)!

    var onSamples: (([Float]) -> Void)?
    var onError: ((Error) -> Void)?
    var onStatus: ((String) -> Void)?

    func start() async throws {
        // Don't block on CGPreflight/CGRequest — on current macOS those often
        // return false with no dialog for locally built apps. ScreenCaptureKit
        // is what actually surfaces Screen Recording / System Audio prompts.
        if !CGPreflightScreenCaptureAccess() {
            debugLog("[audio] CGPreflight=false, calling CGRequestScreenCaptureAccess without waiting")
            _ = CGRequestScreenCaptureAccess()
        }

        onStatus?("Starting capture… allow QuietDraft if macOS asks.")
        let content = try await shareableContentWithRetry()
        guard let display = content.displays.first else {
            throw NSError(domain: "AudioCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: "No display available for audio capture"])
        }

        // We only need audio, but SCContentFilter still requires a display/app target.
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1) // no video needed

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "audio.capture"))
        try await startCaptureWithRetry(stream)
        self.stream = stream
    }

    func stop() async {
        try? await stream?.stopCapture()
        stream = nil
    }

    private var callbackCount = 0
    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        callbackCount += 1
        if callbackCount <= 5 || callbackCount % 100 == 0 {
            debugLog("[audio] didOutputSampleBuffer #\(callbackCount) type=\(type) valid=\(sampleBuffer.isValid)")
        }
        guard type == .audio, sampleBuffer.isValid else { return }
        guard let pcm = sampleBuffer.asPCMBuffer() else {
            debugLog("[audio] asPCMBuffer() returned nil")
            return
        }

        if converter == nil {
            converter = AVAudioConverter(from: pcm.format, to: targetFormat)
            debugLog("[audio] created converter from=\(pcm.format) to=\(targetFormat) success=\(converter != nil)")
        }
        guard let converter else {
            debugLog("[audio] no converter available")
            return
        }

        let ratio = targetFormat.sampleRate / pcm.format.sampleRate
        let outCapacity = AVAudioFrameCount(Double(pcm.frameLength) * ratio) + 16
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outCapacity) else { return }

        var error: NSError?
        var consumed = false
        converter.convert(to: outBuffer, error: &error) { _, outStatus in
            if consumed {
                outStatus.pointee = .noDataNow
                return nil
            }
            consumed = true
            outStatus.pointee = .haveData
            return pcm
        }
        if let error {
            debugLog("[audio] convert error: \(error)")
            onError?(error)
            return
        }
        guard let channel = outBuffer.floatChannelData?[0], outBuffer.frameLength > 0 else {
            debugLog("[audio] outBuffer empty after convert, frameLength=\(outBuffer.frameLength)")
            return
        }
        onSamples?(Array(UnsafeBufferPointer(start: channel, count: Int(outBuffer.frameLength))))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError?(error)
    }

    private func shareableContentWithRetry() async throws -> SCShareableContent {
        var lastError: Error?
        for attempt in 1...12 {
            do {
                return try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            } catch {
                lastError = error
                debugLog("[audio] SCShareableContent attempt \(attempt) failed: \(error)")
                onStatus?("Allow QuietDraft if a permission dialog appears…")
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        throw NSError(
            domain: "AudioCapture",
            code: 3,
            userInfo: [NSLocalizedDescriptionKey: lastError?.localizedDescription ?? Self.permissionHelp]
        )
    }

    private func startCaptureWithRetry(_ stream: SCStream) async throws {
        var lastError: Error?
        for attempt in 1...10 {
            do {
                try await stream.startCapture()
                return
            } catch {
                lastError = error
                debugLog("[audio] startCapture attempt \(attempt) failed: \(error)")
                onStatus?("Allow QuietDraft for System Audio if macOS asks…")
                try await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
        throw NSError(
            domain: "AudioCapture",
            code: 4,
            userInfo: [NSLocalizedDescriptionKey: lastError?.localizedDescription ?? Self.permissionHelp]
        )
    }

    private static let permissionHelp =
        "macOS blocked capture. In System Settings → Privacy & Security → Screen Recording (and System Audio Recording), click +, add QuietDraft.app, turn it on, then quit and reopen QuietDraft."
}

private extension CMSampleBuffer {
    func asPCMBuffer() -> AVAudioPCMBuffer? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(self),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription) else {
            return nil
        }
        guard let format = AVAudioFormat(streamDescription: asbd) else { return nil }

        let numSamples = CMSampleBufferGetNumSamples(self)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(numSamples)) else {
            return nil
        }
        buffer.frameLength = AVAudioFrameCount(numSamples)

        var blockBuffer: CMBlockBuffer?

        // Query the actual size needed (non-interleaved multi-channel audio needs
        // room for N AudioBuffer entries, not just the single one AudioBufferList
        // has room for by default).
        var sizeNeeded: Int = 0
        let sizeStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            self,
            bufferListSizeNeededOut: &sizeNeeded,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: nil
        )
        guard sizeStatus == noErr || sizeStatus == OSStatus(-12737), sizeNeeded > 0 else {
            debugLog("[audio] size query failed status=\(sizeStatus) sizeNeeded=\(sizeNeeded)")
            return nil
        }

        let rawList = UnsafeMutableRawPointer.allocate(byteCount: sizeNeeded, alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { rawList.deallocate() }
        let audioBufferListPtr = rawList.bindMemory(to: AudioBufferList.self, capacity: 1)

        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            self,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferListPtr,
            bufferListSize: sizeNeeded,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard status == noErr else {
            debugLog("[audio] CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer failed status=\(status)")
            return nil
        }

        let dstList = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let srcList = UnsafeMutableAudioBufferListPointer(audioBufferListPtr)
        do {
            if format.isInterleaved {
                if let src = srcList[0].mData, let dst = dstList[0].mData {
                    memcpy(dst, src, Int(srcList[0].mDataByteSize))
                }
            } else {
                for i in 0..<Int(format.channelCount) {
                    guard i < srcList.count, i < dstList.count,
                          let src = srcList[i].mData, let dst = dstList[i].mData else { continue }
                    memcpy(dst, src, Int(srcList[i].mDataByteSize))
                }
            }
        }
        return buffer
    }
}
