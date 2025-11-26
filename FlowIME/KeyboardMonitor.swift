//
//  KeyboardMonitor.swift
//  FlowIME
//
//  Created by taro hirose on 2025/11/26.
//

import Cocoa
import Carbon

class KeyboardMonitor {
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var lastCheckTime: Date?
    private let throttleInterval: TimeInterval = 1.0
    private var lastNavigationTime: Date?
    private let navGraceWindow: TimeInterval = 0.12 // seconds
    private let deferDecisionInterval: TimeInterval = 0.03 // seconds

    // Called asynchronously after key event (for logging, etc.)
    var onAlphabetInput: (() -> Void)?
    // Decide desired input mode BEFORE the key is delivered (called in tap thread)
    // Return nil to keep current mode and not consume the event.
    var onPreAlphabetInputDecide: (() -> IMEController.InputMode?)?
    weak var imeController: IMEController?

    // Timestamp of the last real (non-synthetic) alphabet keyDown
    private(set) var lastUserAlphabetTime: Date?

    init() {}

    func startMonitoring() {
        // Create event tap for key down/up events
        let eventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue)

        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon = refcon else {
                    return Unmanaged.passUnretained(event)
                }

                let monitor = Unmanaged<KeyboardMonitor>.fromOpaque(refcon).takeUnretainedValue()
                if monitor.processEvent(type: type, event: event) {
                    // Event consumed (we re-injected already)
                    return nil
                } else {
                    return Unmanaged.passUnretained(event)
                }
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("❌ Failed to create event tap. Make sure accessibility permissions are granted.")
            return
        }

        self.eventTap = eventTap

        // Create run loop source
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)

        guard let runLoopSource = runLoopSource else {
            print("❌ Failed to create run loop source")
            return
        }

        // Add to current run loop
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)

        // Enable the event tap
        CGEvent.tapEnable(tap: eventTap, enable: true)

        print("✅ Keyboard monitoring started")
        print("💡 Type alphabet characters to trigger IME switching")
        print("⏱️  Throttle interval: \(throttleInterval) seconds")
    }

    func stopMonitoring() {
        if let eventTap = eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }

        if let runLoopSource = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        }

        eventTap = nil
        runLoopSource = nil

        print("🛑 Keyboard monitoring stopped")
    }

    // MARK: - Event processing

    // Magic tag to identify synthetic events we post (hex literal)
    private let syntheticTag: Int64 = 0xF10F1AE5
    private var suppressNextKeyUpForKeyCodes = Set<Int64>()

    private func processEvent(type: CGEventType, event: CGEvent) -> Bool {
        // Ignore our own synthetic events
        if event.getIntegerValueField(.eventSourceUserData) == syntheticTag {
            return false
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags

        // Track and optionally consume the original keyUp if we consumed its keyDown earlier
        if type == .keyUp {
            if suppressNextKeyUpForKeyCodes.contains(keyCode) {
                suppressNextKeyUpForKeyCodes.remove(keyCode)
                return true // consume original keyUp
            }
            return false
        }

        // Get key code
        // (already got keyCode / flags above)

        // Record navigation keys (arrow/home/end/page) to improve next decision
        if type == .keyDown, isNavigationKey(keyCode: keyCode) {
            lastNavigationTime = Date()
            return false
        }

        // Check if any modifier keys are pressed (Command, Option, Control)
        // We allow Shift because it's used for capital letters
        let hasModifiers = flags.contains(.maskCommand) ||
                          flags.contains(.maskAlternate) ||
                          flags.contains(.maskControl)

        if hasModifiers {
            // Ignore shortcuts (actual input source change will be observed via DistributedNotification)
            return false
        }

        // Check if this is an alphabet key (a-z)
        if isAlphabetKey(keyCode: keyCode) {
            let now = Date()
            // Record when the user actually pressed an alphabet key (before any consumption)
            lastUserAlphabetTime = now

            // Respect recent explicit user toggle (avoid overriding user's intent)
            if let ime = imeController, ime.isRecentUserToggle(grace: 0.6) {
                return false
            }

            // If navigation just happened, defer processing so cursor position updates first
            if let navAt = lastNavigationTime, now.timeIntervalSince(navAt) < navGraceWindow {
                suppressNextKeyUpForKeyCodes.insert(keyCode)
                DispatchQueue.main.asyncAfter(deadline: .now() + deferDecisionInterval) { [weak self] in
                    guard let self = self else { return }
                    let desired = self.onPreAlphabetInputDecide?()
                    if let desiredMode = desired, let ime = self.imeController {
                        let current = ime.getCurrentInputMode()
                        if current != desiredMode {
                            ime.switchToInputMode(desiredMode)
                        }
                    }
                    self.postSyntheticKey(keyCode: keyCode, flags: flags, keyDown: true)
                    self.postSyntheticKey(keyCode: keyCode, flags: flags, keyDown: false)
                    DispatchQueue.main.async { [weak self] in self?.onAlphabetInput?() }
                }
                return true // consume original
            }

            // Ask desired mode first; if switch needed, bypass throttle
            let desired = onPreAlphabetInputDecide?()
            if let desiredMode = desired, let ime = imeController {
                let current = ime.getCurrentInputMode()
                if current != desiredMode {
                    print("⌨️  Alphabet key pressed (code: \(keyCode)), switching immediately")
                    lastCheckTime = now
                    ime.switchToInputMode(desiredMode)
                    postSyntheticKey(keyCode: keyCode, flags: flags, keyDown: true)
                    postSyntheticKey(keyCode: keyCode, flags: flags, keyDown: false)
                    suppressNextKeyUpForKeyCodes.insert(keyCode)
                    DispatchQueue.main.async { [weak self] in self?.onAlphabetInput?() }
                    return true
                }
            }

            // Otherwise, apply throttle just for logging/diagnostics
            if let lastCheck = lastCheckTime {
                let elapsed = now.timeIntervalSince(lastCheck)
                if elapsed < throttleInterval {
                    print("⏭️  Alphabet key pressed (code: \(keyCode)), skipped (last check: \(String(format: "%.2f", elapsed))s ago)")
                    return false
                }
            }
            if let lastIMEChange = imeController?.lastInputSourceChangeTime {
                let elapsed = now.timeIntervalSince(lastIMEChange)
                if elapsed < throttleInterval {
                    print("⏭️  Alphabet key pressed (code: \(keyCode)), skipped (IME changed: \(String(format: "%.2f", elapsed))s ago)")
                    return false
                }
            }

            print("⌨️  Alphabet key pressed (code: \(keyCode)), checking now")
            lastCheckTime = now
            DispatchQueue.main.async { [weak self] in self?.onAlphabetInput?() }
            return false
        }

        return false
    }

    private func postSyntheticKey(keyCode: Int64, flags: CGEventFlags, keyDown: Bool) {
        guard let e = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: keyDown) else { return }
        e.flags = flags
        e.setIntegerValueField(.eventSourceUserData, value: syntheticTag)
        e.post(tap: .cghidEventTap)
    }

    private func isAlphabetKey(keyCode: Int64) -> Bool {
        // macOS keyboard key codes for alphabet keys
        let alphabetKeyCodes: Set<Int64> = [
            0,  // A
            11, // B
            8,  // C
            2,  // D
            14, // E
            3,  // F
            5,  // G
            4,  // H
            34, // I
            38, // J
            40, // K
            37, // L
            46, // M
            45, // N
            31, // O
            35, // P
            12, // Q
            15, // R
            1,  // S
            17, // T
            32, // U
            9,  // V
            13, // W
            7,  // X
            16, // Y
            6   // Z
        ]

        return alphabetKeyCodes.contains(keyCode)
    }

    // No shortcut detection needed. We rely on kTISNotifySelectedKeyboardInputSourceChanged
    // handled in IMEController to classify user vs programmatic switches.

    private func isNavigationKey(keyCode: Int64) -> Bool {
        // Arrow keys, Home/End, Page Up/Down
        let navKeys: Set<Int64> = [
            123, // Left Arrow
            124, // Right Arrow
            125, // Down Arrow
            126, // Up Arrow
            115, // Home
            119, // End
            116, // Page Up
            121  // Page Down
        ]
        return navKeys.contains(keyCode)
    }

    deinit {
        stopMonitoring()
    }
}
