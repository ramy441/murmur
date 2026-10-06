import AppKit
import CoreGraphics

/// Global tap-to-toggle on a bare modifier key. Modifier keys never reach the
/// normal hotkey APIs, so this listens to the raw event stream instead.
final class FnHotKey: @unchecked Sendable {
    /// fn/globe. Right-option is the fallback for keyboards where fn is claimed by the OS.
    enum Key: String {
        case fn, rightOption

        var keyCode: Int64 { self == .fn ? 63 : 61 }
        var flag: CGEventFlags { self == .fn ? .maskSecondaryFn : .maskAlternate }
        var label: String { self == .fn ? "fn (globe)" : "right ⌥" }
    }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var isHeld = false
    private let onToggle: @Sendable () -> Void

    var key: Key = .fn

    /// Traces every modifier transition, so a key that never arrives can be told apart
    /// from a key that arrives and gets filtered out.
    var verbose = UserDefaults.standard.bool(forKey: "verboseHotkey")

    init(onToggle: @escaping @Sendable () -> Void) {
        self.onToggle = onToggle
    }

    var hasPermission: Bool { AXIsProcessTrusted() }
    var isActive: Bool { tap != nil }

    @discardableResult
    func start() -> Bool {
        stop()
        guard hasPermission else { return false }

        let mask: CGEventMask = 1 << CGEventType.flagsChanged.rawValue
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return Unmanaged.passUnretained(event) }
            Unmanaged<FnHotKey>.fromOpaque(refcon).takeUnretainedValue().handle(type, event)
            return Unmanaged.passUnretained(event)
        }

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        source = nil
        tap = nil
        isHeld = false
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return
        }
        guard type == .flagsChanged else { return }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let held = event.flags.contains(key.flag)

        if verbose {
            Diagnostics.log("flagsChanged keycode=\(keyCode) fnFlag=\(held) flags=\(event.flags.rawValue)")
        }

        guard held != isHeld else { return }
        isHeld = held
        guard held else { return }

        // The globe key reports keycode 63 on some keyboards and 0 on others, so the
        // modifier transition is the real signal. Ignore it when it is only a companion
        // to another modifier chord.
        guard keyCode == key.keyCode || keyCode == 0 else { return }
        guard event.flags.isDisjoint(with: [.maskCommand, .maskControl, .maskShift]) else { return }

        Diagnostics.log("trigger \(key.rawValue) pressed")
        let fire = onToggle
        DispatchQueue.main.async { fire() }
    }
}
