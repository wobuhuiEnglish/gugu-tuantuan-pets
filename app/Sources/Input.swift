import AppKit
import IOKit.hid

/// Optional mouse and keyboard tweaks. All are off by default.
/// - Mouse wheel scrolls the classic (Windows) way while the trackpad keeps natural scrolling.
/// - Mouse side buttons 4/5 run a chosen action.
/// - External keyboards: Ctrl→Command, Win→Option, Alt→Control (via hidutil, built-in keyboard untouched).
/// - Alt+Tab (Alt is Control after the remap) opens the app switcher like Command+Tab.
/// Everything except the key remap needs the Accessibility permission, asked for only when one is turned on.
final class InputTweaks: NSObject {
    enum SideAction: String, CaseIterable {
        case none, back, forward, copy, paste, missionControl, showDesktop
        var title: String {
            switch self {
            case .none: return "不改"
            case .back: return "返回"
            case .forward: return "前进"
            case .copy: return "复制"
            case .paste: return "粘贴"
            case .missionControl: return "调度中心"
            case .showDesktop: return "显示桌面"
            }
        }
    }

    private let settings = UserDefaults.standard
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var hid: IOHIDManager?
    private var switching = false   // Command is being held on the user's behalf for the app switcher
    private var permissionTimer: Timer?

    var mouseClassic: Bool { settings.bool(forKey: "input.mouseClassic") }
    var keyRemap: Bool { settings.bool(forKey: "input.keyRemap") }
    var altTab: Bool { settings.bool(forKey: "input.altTab") }
    func side(_ n: Int) -> SideAction { SideAction(rawValue: settings.string(forKey: "input.side\(n)") ?? "") ?? .none }
    private var needsTap: Bool { mouseClassic || altTab || side(4) != .none || side(5) != .none }

    func start() {
        applyKeyRemap()
        watchKeyboards()
        if needsTap { startTap(prompt: false) }
    }

    // MARK: Menu

    func menuItem() -> NSMenuItem {
        let root = NSMenuItem(title: "🖱 滚轮、侧键、外接键盘…", action: nil, keyEquivalent: "")
        let m = NSMenu()
        func add(_ title: String, _ sel: Selector?, to menu: NSMenu = m, rep: Any? = nil, on: Bool? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            item.target = sel == nil ? nil : self
            item.representedObject = rep
            if let on = on { item.state = on ? .on : .off }
            menu.addItem(item)
            return item
        }
        _ = add("鼠标滚轮用传统方向（触控板不变）", #selector(toggleMouse), on: mouseClassic)
        for n in [4, 5] {
            let item = add("鼠标侧键 \(n)：\(side(n).title)", nil)
            let choices = NSMenu()
            for a in SideAction.allCases {
                _ = add(a.title, #selector(setSide(_:)), to: choices, rep: "\(n):\(a.rawValue)", on: side(n) == a)
            }
            item.submenu = choices
            item.action = #selector(noop); item.target = self
        }
        m.addItem(.separator())
        _ = add("外接键盘：Ctrl→⌘  Win→⌥  Alt→⌃", #selector(toggleRemap), on: keyRemap)
        _ = add("Alt+Tab 切换窗口", #selector(toggleAltTab), on: altTab)
        if needsTap && !AXIsProcessTrusted() {
            m.addItem(.separator())
            _ = add("⚠️ 需要“辅助功能”权限才能生效…", #selector(openPrivacy))
        }
        root.submenu = m
        return root
    }

    @objc private func noop() {}
    @objc private func toggleMouse() { settings.set(!mouseClassic, forKey: "input.mouseClassic"); refreshTap() }
    @objc private func toggleAltTab() { settings.set(!altTab, forKey: "input.altTab"); refreshTap() }
    @objc private func setSide(_ s: NSMenuItem) {
        guard let v = s.representedObject as? String else { return }
        let parts = v.split(separator: ":")
        settings.set(String(parts[1]), forKey: "input.side\(parts[0])")
        refreshTap()
    }
    @objc private func toggleRemap() {
        settings.set(!keyRemap, forKey: "input.keyRemap")
        applyKeyRemap()
    }
    @objc private func openPrivacy() {
        _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    // MARK: Event tap (scroll, side buttons, Alt+Tab)

    private func refreshTap() {
        if needsTap { startTap(prompt: true) } else { stopTap() }
    }

    private func startTap(prompt: Bool) {
        if tap != nil { return }
        guard AXIsProcessTrusted() else {
            if prompt { openPrivacy() }
            // Start by itself as soon as the user grants the permission.
            permissionTimer?.invalidate()
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
                guard let self = self else { t.invalidate(); return }
                if !self.needsTap { t.invalidate(); return }
                if AXIsProcessTrusted() { t.invalidate(); self.startTap(prompt: false) }
            }
            return
        }
        let types: [CGEventType] = [.scrollWheel, .otherMouseDown, .otherMouseUp, .keyDown, .flagsChanged]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let me = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: { _, type, event, info in
            let me = Unmanaged<InputTweaks>.fromOpaque(info!).takeUnretainedValue()
            return me.handle(type, event)
        }, userInfo: me) else { return }
        tap = port
        tapSource = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), tapSource, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
    }

    private func stopTap() {
        permissionTimer?.invalidate()
        if let port = tap { CGEvent.tapEnable(tap: port, enable: false) }
        if let src = tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), src, .commonModes) }
        tap = nil; tapSource = nil
        if switching { postCommand(down: false) }
    }

    /// Our own synthetic events carry this tag so the tap lets them through untouched.
    private let marker: Int64 = 0x63617470   // "catp"

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let port = tap { CGEvent.tapEnable(tap: port, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == marker { return Unmanaged.passUnretained(event) }
        switch type {
        case .scrollWheel:
            // Trackpads (and Magic Mouse) send continuous scrolling; a wheel mouse sends line steps.
            if mouseClassic, event.getIntegerValueField(.scrollWheelEventIsContinuous) == 0, naturalScrolling {
                for (d, p, f) in [(CGEventField.scrollWheelEventDeltaAxis1, CGEventField.scrollWheelEventPointDeltaAxis1, CGEventField.scrollWheelEventFixedPtDeltaAxis1),
                                  (.scrollWheelEventDeltaAxis2, .scrollWheelEventPointDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis2)] {
                    event.setIntegerValueField(d, value: -event.getIntegerValueField(d))
                    event.setIntegerValueField(p, value: -event.getIntegerValueField(p))
                    event.setDoubleValueField(f, value: -event.getDoubleValueField(f))
                }
            }
        case .otherMouseDown, .otherMouseUp:
            // Button numbers start at 0: 3 is the "back" side button (4), 4 the "forward" one (5).
            let n = Int(event.getIntegerValueField(.mouseEventButtonNumber)) + 1
            if n == 4 || n == 5, side(n) != .none {
                if type == .otherMouseDown { DispatchQueue.main.async { self.run(self.side(n)) } }
                return nil
            }
        case .keyDown:
            // Tab with Control (the remapped Alt) → the Command+Tab app switcher.
            if altTab, event.getIntegerValueField(.keyboardEventKeycode) == 48 {
                var flags = event.flags
                if flags.contains(.maskControl) && !flags.contains(.maskCommand) {
                    if !switching { switching = true; postCommand(down: true) }
                    flags.remove(.maskControl); flags.insert(.maskCommand)
                    event.flags = flags
                }
            }
        case .flagsChanged:
            if switching && !event.flags.contains(.maskControl) {
                switching = false
                postCommand(down: false)
            }
        default: break
        }
        return Unmanaged.passUnretained(event)
    }

    private var naturalScrolling: Bool {
        (UserDefaults.standard.object(forKey: "com.apple.swipescrolldirection") as? Bool) ?? true
    }

    private func postCommand(down: Bool) {
        let src = CGEventSource(stateID: .hidSystemState)
        guard let e = CGEvent(keyboardEventSource: src, virtualKey: 55, keyDown: down) else { return }
        e.flags = down ? .maskCommand : []
        e.setIntegerValueField(.eventSourceUserData, value: marker)
        e.post(tap: .cgSessionEventTap)
    }

    private func pressKeys(_ key: CGKeyCode, _ flags: CGEventFlags) {
        let src = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let e = CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: down) else { continue }
            e.flags = flags
            e.setIntegerValueField(.eventSourceUserData, value: marker)
            e.post(tap: .cgSessionEventTap)
        }
    }

    private func run(_ a: SideAction) {
        switch a {
        case .none: break
        case .back: pressKeys(33, .maskCommand)      // ⌘[
        case .forward: pressKeys(30, .maskCommand)   // ⌘]
        case .copy: pressKeys(8, .maskCommand)       // ⌘C
        case .paste: pressKeys(9, .maskCommand)      // ⌘V
        case .missionControl: dock("com.apple.expose.awake", fallbackApp: "/System/Applications/Mission Control.app")
        case .showDesktop: dock("com.apple.showdesktop.awake", fallbackApp: nil)
        }
    }

    /// Asks the Dock to open Mission Control / show the desktop.
    private func dock(_ note: String, fallbackApp: String?) {
        typealias Send = @convention(c) (CFString, Int32) -> Void
        if let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CoreDockSendNotification") {
            unsafeBitCast(sym, to: Send.self)(note as CFString, 0)
        } else if let app = fallbackApp {
            NSWorkspace.shared.open(URL(fileURLWithPath: app))
        }
    }

    // MARK: External keyboard modifiers (hidutil, no permission needed)

    private struct Keyboard: Hashable { let vendor: Int; let product: Int }
    private var keyboards = Set<Keyboard>()

    private func watchKeyboards() {
        let m = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(m, [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Keyboard] as CFDictionary)
        let me = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(m, { info, _, _, device in
            let me = Unmanaged<InputTweaks>.fromOpaque(info!).takeUnretainedValue()
            me.keyboardAttached(device)
        }, me)
        IOHIDManagerScheduleWithRunLoop(m, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        IOHIDManagerOpen(m, IOOptionBits(kIOHIDOptionsTypeNone))
        hid = m
    }

    private func keyboardAttached(_ device: IOHIDDevice) {
        func prop(_ k: String) -> Any? { IOHIDDeviceGetProperty(device, k as CFString) }
        if (prop("Built-In") as? Bool) == true { return }
        if let transport = prop(kIOHIDTransportKey) as? String, ["SPI", "FIFO"].contains(transport) { return }   // internal keyboards
        guard let v = prop(kIOHIDVendorIDKey) as? Int, let p = prop(kIOHIDProductIDKey) as? Int else { return }
        if v == 0x5ac { return }   // Apple keyboards already have Mac keys
        keyboards.insert(Keyboard(vendor: v, product: p))
        // Let the keyboard finish connecting before setting its mapping.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.applyKeyRemap() }
    }

    private func applyKeyRemap(_ on: Bool? = nil) {
        // HID usages: E0/E4 Ctrl, E2/E6 Alt, E3/E7 Win (Command on a Mac).
        let pairs: [(Int, Int)] = [(0xE0, 0xE3), (0xE3, 0xE2), (0xE2, 0xE0), (0xE4, 0xE7), (0xE7, 0xE6), (0xE6, 0xE4)]
        let mapping = (on ?? keyRemap)
            ? "[" + pairs.map { "{\"HIDKeyboardModifierMappingSrc\":\(0x700000000 + $0.0),\"HIDKeyboardModifierMappingDst\":\(0x700000000 + $0.1)}" }.joined(separator: ",") + "]"
            : "[]"
        for k in keyboards {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/hidutil")
            p.arguments = ["property", "--matching", "{\"VendorID\":\(k.vendor),\"ProductID\":\(k.product)}",
                           "--set", "{\"UserKeyMapping\":\(mapping)}"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try? p.run()
        }
    }

    /// Put external keyboards back to normal when quitting.
    func stop() {
        stopTap()
        if keyRemap { applyKeyRemap(false) }
    }
}
