import Foundation

/// Append-only trace of the things that are invisible from outside the app —
/// whether the key listener fired, which engine ran, why a run was refused.
enum Diagnostics {
    private static let queue = DispatchQueue(label: "murmur.diagnostics")

    static func log(_ message: String) {
        let stamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(stamp)  \(message)\n"
        queue.async {
            let url = Paths.support.appendingPathComponent("events.log")
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile()
                handle.write(Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}
