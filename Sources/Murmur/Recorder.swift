import AVFoundation

/// Captures the mic straight to a 16 kHz mono WAV — the format every Whisper build wants.
/// The tap callback runs on a realtime thread, so nothing here touches the main actor.
final class Recorder: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var file: AVAudioFile?
    private var converter: AVAudioConverter?
    private var tapped = false
    private var frames: AVAudioFramePosition = 0
    private var writeErrorCount = 0
    private var firstWriteError: String?
    private var pressTime: Date?
    private var firstBufferSeen = false
    private var configChangeHandled = false
    private var configObserver: NSObjectProtocol?

    private(set) var url: URL?

    var duration: TimeInterval { Double(frames) / 16_000 }

    /// Fires once per `start()`, on the realtime tap thread, the moment the first buffer lands.
    var onFirstBuffer: (() -> Void)?

    init() {
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in self?.handleConfigurationChange() }
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
    }

    func start() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("murmur-\(UUID().uuidString).wav")
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16_000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        self.file = file
        self.url = url
        frames = 0
        writeErrorCount = 0
        firstWriteError = nil
        firstBufferSeen = false
        configChangeHandled = false
        pressTime = Date()

        let inputFormat = engine.inputNode.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0 else { throw MurmurError.noInputDevice }
        installTap(format: inputFormat)

        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }
    }

    /// Returns the finished WAV, or nil if the clip was too short to be speech.
    @discardableResult
    func stop() -> URL? {
        if tapped { engine.inputNode.removeTap(onBus: 0) }
        tapped = false
        engine.pause() // the audio unit stays configured, so the next press delivers buffers without a cold start
        converter = nil
        file = nil

        let errSuffix = firstWriteError.map { " writeErrors=\(writeErrorCount) first=\($0)" } ?? ""
        Diagnostics.log("recorder: stopped frames=\(frames) duration=\(String(format: "%.2f", duration))s\(errSuffix)")

        let finished = url
        url = nil
        guard duration >= 0.35 else {
            if let finished { try? FileManager.default.removeItem(at: finished) }
            return nil
        }
        return finished
    }

    private func installTap(format: AVAudioFormat) {
        engine.inputNode.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.handle(buffer)
        }
        tapped = true
    }

    private func handle(_ buffer: AVAudioPCMBuffer) {
        if !firstBufferSeen {
            firstBufferSeen = true
            if let pressTime {
                let ms = Int(Date().timeIntervalSince(pressTime) * 1000)
                Diagnostics.log("recorder: first buffer after \(ms) ms")
            }
            onFirstBuffer?()
        }
        guard let file, let converted = convert(buffer, to: file.processingFormat) else { return }
        do {
            try file.write(from: converted)
        } catch {
            writeErrorCount += 1
            if firstWriteError == nil { firstWriteError = error.localizedDescription }
        }
        frames += AVAudioFramePosition(converted.frameLength)
    }

    /// A mid-recording input-device change (headphones plugged in, AirPods connected) stops the
    /// existing tap silently — reinstall it on the new format rather than losing the rest of the take.
    private func handleConfigurationChange() {
        guard tapped, !configChangeHandled else { return }
        configChangeHandled = true
        Diagnostics.log("recorder: input device changed mid-recording, frames kept=\(frames)")

        if tapped { engine.inputNode.removeTap(onBus: 0) }
        let newFormat = engine.inputNode.outputFormat(forBus: 0)
        guard newFormat.sampleRate > 0 else {
            tapped = false
            Diagnostics.log("recorder: tap restart failed — no input format after device change")
            return
        }
        do {
            if !engine.isRunning {
                engine.prepare()
                try engine.start()
            }
            installTap(format: newFormat)
            Diagnostics.log("recorder: tap restarted on new input format")
        } catch {
            tapped = false
            Diagnostics.log("recorder: tap restart failed — \(error.localizedDescription)")
        }
    }

    private func convert(_ buffer: AVAudioPCMBuffer, to outputFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        if buffer.format == outputFormat { return buffer }

        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: outputFormat)
            converter?.primeMethod = .none
        }
        guard let converter else { return nil }

        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return nil }

        var error: NSError?
        var delivered = false
        converter.convert(to: out, error: &error) { _, status in
            if delivered {
                status.pointee = .noDataNow
                return nil
            }
            delivered = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0 else { return nil }
        return out
    }
}

enum MurmurError: LocalizedError {
    case noInputDevice
    case modelMissing
    case engineFailed(String)

    var errorDescription: String? {
        switch self {
        case .noInputDevice: return "No microphone input available."
        case .modelMissing: return "Whisper model not downloaded yet."
        case .engineFailed(let detail): return detail
        }
    }
}
