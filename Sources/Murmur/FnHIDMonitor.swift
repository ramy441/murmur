import Foundation
import IOKit.hid

/// Reads the globe/fn key straight off the HID device.
///
/// With "Press 🌐 key to → Do Nothing", the window server discards the fn key before any
/// `CGEventTap` or `NSEvent` monitor can see it — the key genuinely does not exist at that
/// layer. Apple reports it on its own vendor usage page, which is still readable here.
///
/// Needs Input Monitoring rather than Accessibility.
final class FnHIDMonitor: @unchecked Sendable {
    private static let appleVendorTopCase = 0x00FF
    private static let keyboardFnUsage = 0x0003

    private var manager: IOHIDManager?
    private var isHeld = false
    private let onPress: @Sendable () -> Void

    init(onPress: @escaping @Sendable () -> Void) {
        self.onPress = onPress
    }

    var hasPermission: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    @discardableResult
    func requestPermission() -> Bool {
        IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
    }

    @discardableResult
    func start() -> Bool {
        stop()
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

        let matching: [[String: Any]] = [
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard],
            [kIOHIDDeviceUsagePageKey: Self.appleVendorTopCase, kIOHIDDeviceUsageKey: Self.keyboardFnUsage],
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matching as CFArray)

        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(manager, { context, _, _, value in
            guard let context else { return }
            Unmanaged<FnHIDMonitor>.fromOpaque(context).takeUnretainedValue().handle(value)
        }, context)

        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
            return false
        }
        self.manager = manager
        return true
    }

    func stop() {
        guard let manager else { return }
        IOHIDManagerUnscheduleFromRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        self.manager = nil
        isHeld = false
    }

    var isActive: Bool { manager != nil }

    private func handle(_ value: IOHIDValue) {
        let element = IOHIDValueGetElement(value)
        guard Int(IOHIDElementGetUsagePage(element)) == Self.appleVendorTopCase,
              Int(IOHIDElementGetUsage(element)) == Self.keyboardFnUsage else { return }

        let held = IOHIDValueGetIntegerValue(value) != 0
        guard held != isHeld else { return }
        isHeld = held
        guard held else { return }

        Diagnostics.log("trigger fn pressed (HID)")
        let fire = onPress
        DispatchQueue.main.async { fire() }
    }
}
