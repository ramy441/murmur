import AVFoundation
import AppKit

enum DictationState: Equatable {
    case idle
    case recording
    case thinking
    case failed(String)
}

@MainActor
final class DictationEngine {
    var onStateChange: ((DictationState) -> Void)?

    private(set) var state: DictationState = .idle {
        didSet { onStateChange?(state) }
    }
    private(set) var activeEngine = "—"
    private(set) var lastTranscript = ""

    private let recorder = Recorder()
    private let parakeet = ParakeetEngine()

    /// True from the fn press until stop, independent of `state` — `state` only flips to
    /// `.recording` once the first buffer arrives, so toggle() needs its own source of truth.
    private var isCapturing = false

    var soundEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "sound") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "sound") }
    }

    var polishEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "polish") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "polish") }
    }

    var isBusy: Bool { isCapturing || state == .thinking }

    /// Loads the model into memory ahead of the first dictation, retrying while a
    /// first-run download is still in flight.
    func warmUp() {
        Task {
            while !enginesReady {
                activeEngine = "downloading speech model…"
                try? await Task.sleep(nanoseconds: 30_000_000_000)
            }
            activeEngine = await parakeet.warmUp() ? parakeet.label : "no engine available"
        }
    }

    var enginesReady: Bool { parakeet.isAvailable }

    func toggle() {
        Diagnostics.log("toggle while \(state) · capturing=\(isCapturing) · parakeet=\(parakeet.isAvailable)")
        if isCapturing {
            finish()
        } else if state == .thinking {
            state = .idle // escape hatch — never leave the user stuck
        } else {
            begin()
        }
    }

    // MARK: -

    private func begin() {
        guard enginesReady else {
            fail("Speech model still downloading — try again in a few minutes")
            return
        }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            startRecording()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in
                    granted ? self.startRecording() : self.fail("Microphone access denied")
                }
            }
        default:
            fail("Microphone access denied — enable it in System Settings › Privacy")
        }
    }

    private func startRecording() {
        isCapturing = true
        recorder.onFirstBuffer = { [weak self] in
            Task { @MainActor in
                guard let self, self.isCapturing else { return }
                self.state = .recording
                self.chime("Tink")
            }
        }
        do {
            try recorder.start()
        } catch {
            isCapturing = false
            fail(error.localizedDescription)
        }
    }

    private func finish() {
        isCapturing = false
        guard let wav = recorder.stop() else {
            Diagnostics.log("finish: recording too short (\(String(format: "%.2f", recorder.duration))s) — discarded")
            state = .idle
            return
        }
        let duration = recorder.duration
        state = .thinking
        chime("Morse")
        Task { await process(wav, duration: duration) }
    }

    private func process(_ wav: URL, duration: TimeInterval) async {
        defer { try? FileManager.default.removeItem(at: wav) }
        let durationLabel = String(format: "%.2f", duration)

        var text: String
        do {
            let transcript = try await parakeet.transcribe(wav, polish: polishEnabled)
            activeEngine = parakeet.label
            text = transcript.raw
            if let note = transcript.polishNote {
                Diagnostics.log("polish: kept raw — \(note)")
            }
            if let clean = transcript.clean, polishEnabled {
                Diagnostics.log("polish: \(text.split(separator: " ").count) words → \(clean.split(separator: " ").count) in \(transcript.polishMs ?? 0) ms · raw: \(text)")
                text = clean
            }
        } catch {
            Diagnostics.log("process: transcription failed after \(durationLabel)s — \(error.localizedDescription)")
            fail(error.localizedDescription)
            return
        }

        text = Cleanup.scrub(text)
        guard !text.isEmpty else {
            Diagnostics.log("process: empty transcript after \(durationLabel)s recording — discarded")
            state = .idle
            return
        }

        lastTranscript = text
        let saved = HistoryStore.append(text, engine: activeEngine) // durable before the paste, which can fail
        if !saved {
            Diagnostics.log("process: history write failed for \(durationLabel)s recording")
        }
        if !Inserter.insert(text) {
            Diagnostics.log("process: insert failed for \(durationLabel)s recording")
        }
        if saved {
            state = .idle
            chime("Pop")
        } else {
            fail("Could not save to history")
        }
    }

    private func fail(_ message: String) {
        Diagnostics.log("fail: \(message)")
        state = .failed(message)
        chime("Basso")
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            if case .failed = state { state = .idle }
        }
    }

    private func chime(_ name: String) {
        guard soundEnabled else { return }
        NSSound(named: name)?.play()
    }

    func shutdown() {
        Task { await parakeet.shutdown() }
    }
}
