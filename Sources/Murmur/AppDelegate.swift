import AppKit
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let engine = DictationEngine()
    private let hud = HUD()
    private lazy var historyWindow = HistoryWindowController()
    private var hotkey: FnHotKey!
    private var fnMonitor: FnHIDMonitor!

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.menu = buildMenu()

        engine.onStateChange = { [weak self] state in
            self?.render(state)
            self?.hud.update(state)
        }
        render(.idle)

        hotkey = FnHotKey { [weak self] in
            MainActor.assumeIsolated { self?.engine.toggle() }
        }
        fnMonitor = FnHIDMonitor { [weak self] in
            MainActor.assumeIsolated { self?.engine.toggle() }
        }
        hotkey.key = FnHotKey.Key(rawValue: UserDefaults.standard.string(forKey: "hotkey") ?? "fn") ?? .fn

        applyTrigger()
        engine.warmUp()
        writeDiagnostics()
    }

    /// fn has to be read at the HID layer; every other modifier comes through the event tap.
    private func applyTrigger() {
        hotkey.stop()
        fnMonitor.stop()

        guard hotkey.key == .fn else {
            if !hotkey.start() { requestAccessibility() }
            return
        }
        if !fnMonitor.hasPermission { fnMonitor.requestPermission() }
        if !fnMonitor.start() { requestInputMonitoring() }
    }

    private var triggerActive: Bool {
        hotkey.key == .fn ? fnMonitor.isActive : hotkey.isActive
    }

    /// Launch-time snapshot of the two things that silently break dictation.
    private func writeDiagnostics() {
        let lines = """
        launched \(ISO8601DateFormatter().string(from: Date()))
        accessibility_trusted \(hotkey.hasPermission)
        input_monitoring_granted \(fnMonitor.hasPermission)
        hotkey_active \(triggerActive)
        trigger_key \(hotkey.key.label)
        parakeet_ready \(Paths.parakeetReady)
        parakeet_model_downloaded \(Paths.parakeetModelReady)

        """
        try? lines.write(to: Paths.support.appendingPathComponent("status.log"),
                         atomically: true, encoding: .utf8)
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkey?.stop()
        engine.shutdown()
    }

    // MARK: - Status item

    private func render(_ state: DictationState) {
        guard let button = statusItem.button else { return }
        let symbol: String
        let tint: NSColor
        switch state {
        case .idle: (symbol, tint) = ("mic", .labelColor)
        case .recording: (symbol, tint) = ("mic.fill", .systemRed)
        case .thinking: (symbol, tint) = ("waveform", .systemBlue)
        case .failed: (symbol, tint) = ("exclamationmark.triangle.fill", .systemOrange)
        }
        let config = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
            .applying(.init(paletteColors: [tint]))
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Murmur")?
            .withSymbolConfiguration(config)
    }

    // MARK: - Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let status = NSMenuItem(title: statusLine(), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        add(menu, "Start / Stop Dictation", #selector(toggleDictation))
        let hint = NSMenuItem(title: "Press \(hotkey.key.label) anywhere", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())

        add(menu, "Sound cues", #selector(toggleSound), checked: engine.soundEnabled)
        add(menu, "Smart cleanup", #selector(togglePolish), checked: engine.polishEnabled)

        let hotkeyItem = NSMenuItem(title: "Trigger key", action: nil, keyEquivalent: "")
        let hotkeyMenu = NSMenu()
        for key in [FnHotKey.Key.fn, .rightOption] {
            let item = NSMenuItem(title: key.label, action: #selector(pickHotkey(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = key.rawValue
            item.state = hotkey.key == key ? .on : .off
            hotkeyMenu.addItem(item)
        }
        hotkeyItem.submenu = hotkeyMenu
        menu.addItem(hotkeyItem)
        menu.addItem(.separator())

        add(menu, "History", #selector(showHistory))
        if !engine.lastTranscript.isEmpty {
            add(menu, "Copy last transcript", #selector(copyLast))
        }
        add(menu, "Launch at login", #selector(toggleLoginItem), checked: SMAppService.mainApp.status == .enabled)
        if !hotkey.hasPermission {
            add(menu, "⚠️ Grant Accessibility access…", #selector(requestAccessibility))
        }
        if hotkey.key == .fn, !fnMonitor.hasPermission {
            add(menu, "⚠️ Grant Input Monitoring access…", #selector(requestInputMonitoring))
        }
        menu.addItem(.separator())
        add(menu, "Quit Murmur", #selector(quit))
    }

    private func statusLine() -> String {
        switch engine.state {
        case .recording: return "● Listening"
        case .thinking: return "◍ Transcribing"
        case .failed(let message): return "⚠️ \(message)"
        case .idle: return "Ready · \(engine.activeEngine)"
        }
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, _ action: Selector, checked: Bool? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        if let checked { item.state = checked ? .on : .off }
        menu.addItem(item)
        return item
    }

    // MARK: - Actions

    @objc private func toggleDictation() { engine.toggle() }
    @objc private func toggleSound() { engine.soundEnabled.toggle() }
    @objc private func togglePolish() { engine.polishEnabled.toggle() }

    @objc private func showHistory() { historyWindow.show() }

    @objc private func copyLast() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(engine.lastTranscript, forType: .string)
    }

    @objc private func pickHotkey(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let key = FnHotKey.Key(rawValue: raw) else { return }
        hotkey.key = key
        UserDefaults.standard.set(raw, forKey: "hotkey")
        applyTrigger()
        writeDiagnostics()
    }

    @objc private func requestInputMonitoring() {
        fnMonitor.requestPermission()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func toggleLoginItem() {
        if SMAppService.mainApp.status == .enabled {
            try? SMAppService.mainApp.unregister()
        } else {
            try? SMAppService.mainApp.register()
        }
    }

    @objc private func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
