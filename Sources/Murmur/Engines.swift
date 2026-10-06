import Foundation

struct Transcript: Sendable {
    let raw: String
    let clean: String?
    let polishMs: Int?
    let polishNote: String?
}

protocol TranscriptionEngine: Sendable {
    var label: String { get }
    var isAvailable: Bool { get }
    func transcribe(_ wav: URL, polish: Bool) async throws -> Transcript
}

// MARK: - Long-lived child process speaking one JSON line per request

final class LineProcess: @unchecked Sendable {
    private let process = Process()
    private let inPipe = Pipe()
    private let outPipe = Pipe()
    private let errPipe = Pipe()
    private var buffer = Data()

    init(executable: String, arguments: [String], environment: [String: String] = [:]) {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        // launched from Finder the app inherits a bare PATH, and parakeet_mlx shells out to ffmpeg
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
        env.merge(environment) { _, new in new }
        process.environment = env
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe
    }

    var isRunning: Bool { process.isRunning }

    func launch() throws {
        try process.run()
        // drain stderr so a chatty child can never fill the pipe and deadlock
        errPipe.fileHandleForReading.readabilityHandler = { $0.availableData.count > 0 ? () : () }
    }

    func send(_ line: String) {
        guard process.isRunning else { return }
        inPipe.fileHandleForWriting.write(Data((line + "\n").utf8))
    }

    /// Blocking — always call from a background queue.
    func readLine(timeout: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let range = buffer.firstRange(of: Data([0x0A])) {
                let line = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                buffer.removeSubrange(buffer.startIndex..<range.upperBound)
                return String(decoding: line, as: UTF8.self)
            }
            guard Date() < deadline, process.isRunning || !buffer.isEmpty else { return nil }
            let chunk = outPipe.fileHandleForReading.availableData
            if chunk.isEmpty {
                guard process.isRunning else { return nil }
                usleep(20_000)
            } else {
                buffer.append(chunk)
            }
        }
    }

    func terminate() {
        errPipe.fileHandleForReading.readabilityHandler = nil
        guard process.isRunning else { return }
        try? inPipe.fileHandleForWriting.close()
        process.terminate()
    }
}

// MARK: - Parakeet TDT v3 (primary)

actor ParakeetEngine: TranscriptionEngine {
    nonisolated let label = "Parakeet TDT v3"
    nonisolated var isAvailable: Bool { Paths.parakeetReady }

    private var worker: LineProcess?
    private let queue = DispatchQueue(label: "murmur.parakeet")

    /// Boots the worker and blocks until the model is resident. Called at app launch
    /// so the first dictation is as fast as the tenth.
    @discardableResult
    func warmUp() async -> Bool {
        guard isAvailable else { return false }
        if let worker, worker.isRunning { return true }

        let proc = LineProcess(
            executable: Paths.venvPython,
            arguments: ["-u", Paths.worker],
            environment: ["HF_HUB_OFFLINE": "1", "HF_HUB_DISABLE_TELEMETRY": "1"]
        )
        do { try proc.launch() } catch { return false }
        worker = proc

        // the weights are already on disk by now, so this is just load time
        let handshake = await run(on: queue) { proc.readLine(timeout: 60) }
        guard let handshake, let data = handshake.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["ready"] as? Bool == true else {
            proc.terminate()
            worker = nil
            return false
        }
        return true
    }

    func transcribe(_ wav: URL, polish: Bool) async throws -> Transcript {
        guard await warmUp(), let worker else { throw MurmurError.engineFailed("Parakeet worker unavailable") }

        let request: [String: Any] = ["path": wav.path, "polish": polish]
        guard let requestData = try? JSONSerialization.data(withJSONObject: request),
              let requestLine = String(data: requestData, encoding: .utf8) else {
            throw MurmurError.engineFailed("Could not encode request")
        }
        let reply = await run(on: queue) { () -> String? in
            worker.send(requestLine)
            return worker.readLine(timeout: 120)
        }

        guard let reply, let data = reply.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            self.worker?.terminate()
            self.worker = nil
            throw MurmurError.engineFailed("Parakeet gave no reply")
        }
        if let error = json["error"] as? String { throw MurmurError.engineFailed(error) }
        return Transcript(
            raw: (json["text"] as? String) ?? "",
            clean: json["clean"] as? String,
            polishMs: json["polish_ms"] as? Int,
            polishNote: (json["polish_rejected"] as? String) ?? (json["polish_error"] as? String)
        )
    }

    func shutdown() {
        worker?.terminate()
        worker = nil
    }

    private func run<T: Sendable>(on queue: DispatchQueue, _ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }
}

// MARK: - Output hygiene

enum Cleanup {
    /// Bracketed sound tags and the stock phrases Whisper emits over silence.
    private static let noise: Set<String> = [
        "thank you.", "thanks for watching!", "thank you for watching!",
        "you", "bye.", "so.", ".", "okay.",
    ]

    static func scrub(_ raw: String) -> String {
        var text = raw
        for pattern in [#"\[[^\]]*\]"#, #"\([^\)]*\)"#, #"\*[^\*]*\*"#] {
            text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return noise.contains(text.lowercased()) ? "" : text
    }
}
