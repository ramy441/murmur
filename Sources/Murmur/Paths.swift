import Foundation

enum Paths {
    static let support: URL = {
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Murmur", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    static var venvPython: String { support.appendingPathComponent("venv/bin/python3").path }
    static var worker: String { support.appendingPathComponent("parakeetd.py").path }

    /// A half-downloaded repo leaves `.incomplete` blobs behind — treating that as ready
    /// is what makes the worker sit there silently redownloading instead of transcribing.
    static var parakeetModelReady: Bool {
        let blobs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cache/huggingface/hub/models--mlx-community--parakeet-tdt-0.6b-v3/blobs")
        guard let items = try? FileManager.default.contentsOfDirectory(atPath: blobs.path),
              !items.isEmpty else { return false }
        return !items.contains { $0.hasSuffix(".incomplete") }
    }

    static var parakeetReady: Bool {
        let fm = FileManager.default
        return fm.isExecutableFile(atPath: venvPython)
            && fm.fileExists(atPath: worker)
            && parakeetModelReady
    }
}
