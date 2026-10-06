import AppKit

/// Floating capsule near the bottom of the screen so the listening state is visible
/// without looking up at the menu bar. Never takes focus from the app you're typing into.
@MainActor
final class HUD {
    private var panel: NSPanel?
    private let dot = NSView()
    private let label = NSTextField(labelWithString: "")

    func update(_ state: DictationState) {
        switch state {
        case .idle:
            hide()
        case .recording:
            show(text: "Listening…", color: .systemRed, pulsing: true)
        case .thinking:
            show(text: "Transcribing…", color: .systemBlue, pulsing: true)
        case .failed(let message):
            show(text: message, color: .systemOrange, pulsing: false)
        }
    }

    private func show(text: String, color: NSColor, pulsing: Bool) {
        let panel = panel ?? makePanel()
        self.panel = panel

        label.stringValue = text
        label.sizeToFit()
        dot.layer?.backgroundColor = color.cgColor
        pulsing ? startPulse() : dot.layer?.removeAllAnimations()

        let width = max(150, label.frame.width + 66)
        if let screen = NSScreen.main {
            let frame = NSRect(
                x: screen.frame.midX - width / 2,
                y: screen.visibleFrame.minY + 96,
                width: width,
                height: 42
            )
            panel.setFrame(frame, display: false)
        }
        layoutContents(width: width)
        panel.orderFrontRegardless()
    }

    private func hide() {
        dot.layer?.removeAllAnimations()
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 180, height: 42),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]

        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 21
        blur.layer?.cornerCurve = .continuous
        blur.layer?.masksToBounds = true

        dot.wantsLayer = true
        dot.layer?.cornerRadius = 5
        label.font = .systemFont(ofSize: 13, weight: .medium)
        label.textColor = .labelColor

        blur.addSubview(dot)
        blur.addSubview(label)
        panel.contentView = blur
        return panel
    }

    private func layoutContents(width: CGFloat) {
        dot.frame = NSRect(x: 20, y: 16, width: 10, height: 10)
        label.frame = NSRect(x: 40, y: 12, width: width - 58, height: 18)
    }

    private func startPulse() {
        dot.layer?.removeAllAnimations()
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.25
        pulse.duration = 0.6
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        dot.layer?.add(pulse, forKey: "pulse")
    }
}
