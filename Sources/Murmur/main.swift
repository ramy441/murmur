import AppKit

// NSApplication holds its delegate weakly, so keep a strong reference alive here.
nonisolated(unsafe) var appDelegate: AppDelegate?

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    appDelegate = delegate
    app.delegate = delegate
    app.run()
}
