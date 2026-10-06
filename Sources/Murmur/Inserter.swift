import AppKit

/// Delivers text to whatever app currently has keyboard focus.
enum Inserter {
    @discardableResult
    static func insert(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        let posted = pressCommandV()

        // give the target app a moment to read the pasteboard before putting it back
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            guard pasteboard.string(forType: .string) == text else { return }
            pasteboard.clearContents()
            if let saved { pasteboard.setString(saved, forType: .string) }
        }
        return posted
    }

    @discardableResult
    private static func pressCommandV() -> Bool {
        let source = CGEventSource(stateID: .combinedSessionState)
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitLocalKeyboardEvents],
            state: .eventSuppressionStateSuppressionInterval
        )
        let v: CGKeyCode = 9
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false) else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cgAnnotatedSessionEventTap)
        up.post(tap: .cgAnnotatedSessionEventTap)
        return true
    }
}
