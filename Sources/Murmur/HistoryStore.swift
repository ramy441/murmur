import Foundation

struct HistoryEntry: Identifiable {
    let id: Int
    let date: Date
    let engine: String
    let text: String
}

enum HistoryStore {
    static let url = Paths.support.appendingPathComponent("history.log")
    static let displayLimit = 50
    // a 1 MB tail always contains far more than displayLimit whole records, whatever their length
    private static let tailBytes: UInt64 = 1_000_000

    static func load() -> [HistoryEntry] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return [] }

        let start = size > tailBytes ? size - tailBytes : 0
        guard (try? handle.seek(toOffset: start)) != nil,
              var bytes = try? handle.readToEnd() else { return [] }

        var offset = Int(start)
        if start > 0 {
            // chunk may start mid-record — drop up to the first newline so only whole records parse
            guard let newlineIndex = bytes.firstIndex(of: 0x0A) else { return [] }
            let dropCount = newlineIndex - bytes.startIndex + 1
            bytes.removeFirst(dropCount)
            offset += dropCount
        }

        let contents = String(decoding: bytes, as: UTF8.self)
        let formatter = ISO8601DateFormatter()

        var entries: [HistoryEntry] = []
        var lineStart = offset
        for line in contents.split(separator: "\n", omittingEmptySubsequences: false) {
            let lineByteLength = line.utf8.count + 1
            defer { lineStart += lineByteLength }
            guard !line.isEmpty else { continue }
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3, let date = formatter.date(from: String(fields[0])) else { continue }
            let text = unescape(String(fields[2]))
            // id = byte offset of the record's line start — stable regardless of where tail-reading began
            entries.append(HistoryEntry(id: lineStart, date: date, engine: String(fields[1]), text: text))
        }
        return Array(entries.reversed().prefix(displayLimit))
    }

    @discardableResult
    static func append(_ text: String, engine: String) -> Bool {
        let line = "\(ISO8601DateFormatter().string(from: Date()))\t\(engine)\t\(escape(text))\n"
        let data = Data(line.utf8)
        if attemptWrite(data) { return true }
        try? FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
        return attemptWrite(data)
    }

    private static func attemptWrite(_ data: Data) -> Bool {
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            do {
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                return true
            } catch {
                Diagnostics.log("HistoryStore.append: write threw — \(error)")
                return false
            }
        }
        if FileManager.default.fileExists(atPath: url.path) {
            Diagnostics.log("HistoryStore.append: open-for-writing failed on existing history.log")
            return false
        }
        do {
            try data.write(to: url)
            return true
        } catch {
            Diagnostics.log("HistoryStore.append: fallback write failed — \(error)")
            return false
        }
    }

    private static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
    }

    private static func unescape(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var chars = text.makeIterator()
        while let char = chars.next() {
            guard char == "\\" else { result.append(char); continue }
            switch chars.next() {
            case "n": result.append("\n")
            case "r": result.append("\r")
            case "\\": result.append("\\")
            case .some(let other): result.append("\\"); result.append(other)
            case nil: result.append("\\")
            }
        }
        return result
    }
}
