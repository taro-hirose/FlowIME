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
    private let throttleInterval: TimeInterval = 0.2
    private var lastNavigationTime: Date?
    private let navGraceWindow: TimeInterval = 0.05 // seconds (micro-deferral for AX to update)
    private let deferDecisionInterval: TimeInterval = 0.05 // seconds

    // Called asynchronously after key event (for logging, etc.)
    var onAlphabetInput: (() -> Void)?
    // Decide desired input mode BEFORE the key is delivered (called in tap thread)
    // Return nil to keep current mode and not consume the event.
    var onPreAlphabetInputDecide: (() -> IMEController.InputMode?)?
    weak var imeController: IMEController?

    // Timestamp of the last real text keyDown (alphabet or Japanese keys)
    private(set) var lastUserTypingTime: Date?
    // Heuristic hold to avoid auto-switch during ongoing JP conversion
    private var compositionHoldUntil: Date?
    private let compositionHoldWindow: TimeInterval = 1.5
    // Track if Space key is currently held (candidate selection etc.)
    private var spacePressed: Bool = false
    // Simple Japanese input session tracking
    private var jpSessionActive: Bool = false
    private var jpSessionCount: Int = 0
    // Hold JP preference briefly after cancelling composition by deletion
    private var canceledJPHoldUntil: Date?

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
    // Anti-flap: remember last programmatic switch
    private var lastProgSwitchAt: Date?
    private var lastProgSwitchMode: IMEController.InputMode?
    private let antiFlapWindow: TimeInterval = 0.35
    // Run lock: keep current run's mode briefly to avoid flicker
    private var runLockMode: IMEController.InputMode?
    private var runLockUntil: Date?
    private let runLockWindow: TimeInterval = 0.2

    private func processEvent(type: CGEventType, event: CGEvent) -> Bool {
        // Ignore our own synthetic events
        if event.getIntegerValueField(.eventSourceUserData) == syntheticTag {
            return false
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let flags = event.flags
        // Check if any modifier keys are pressed (Command, Option, Control)
        // We allow Shift because it's used for capital letters
        let hasModifiers = flags.contains(.maskCommand) ||
                          flags.contains(.maskAlternate) ||
                          flags.contains(.maskControl)

        // Track and optionally consume the original keyUp if we consumed its keyDown earlier
        if type == .keyUp {
            if keyCode == 49 { spacePressed = false }
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
            // Moving the caret: cancel any JP composition hold and space state
            compositionHoldUntil = nil
            spacePressed = false
            // End JP session on navigation
            jpSessionActive = false
            jpSessionCount = 0
            canceledJPHoldUntil = nil
            return false
        }

        // JP composition heuristics: while in JP mode, extend hold on most keys except commits/navigation.
        if type == .keyDown, let ime = imeController, ime.getCurrentInputMode() == .japanese {
            if isSpace(keyCode: keyCode) { spacePressed = true }
            if !isCommitKey(keyCode: keyCode) && !isNavigationKey(keyCode: keyCode) && !hasModifiers {
                compositionHoldUntil = Date().addingTimeInterval(compositionHoldWindow)
                // Count as JP textual input
                jpSessionActive = true
                jpSessionCount &+= 1
                // JP resumed; clear canceled hold
                canceledJPHoldUntil = nil
            }
            if isCommitKey(keyCode: keyCode) {
                compositionHoldUntil = nil
                jpSessionActive = false
                jpSessionCount = 0
                canceledJPHoldUntil = nil
            }
        }

        if hasModifiers {
            // Ignore shortcuts (actual input source change will be observed via DistributedNotification)
            return false
        }

        // Check if this is an alphabet key (a-z)
        if isAlphabetKey(keyCode: keyCode) {
            let now = Date()
            // Record when the user actually pressed a text key (alphabet)
            lastUserTypingTime = now

            // Do not block switching solely due to JP session; composition/space guards handled elsewhere

            // Respect recent explicit user toggle (avoid overriding user's intent)
            if let ime = imeController, ime.isRecentUserToggle(grace: 0.6) {
                // End JP session on explicit user toggle
                jpSessionActive = false
                jpSessionCount = 0
                canceledJPHoldUntil = nil
                return false
            }

            // If navigation just happened, defer processing so cursor position updates first
            if let navAt = lastNavigationTime, now.timeIntervalSince(navAt) < navGraceWindow {
                suppressNextKeyUpForKeyCodes.insert(keyCode)
                DispatchQueue.main.asyncAfter(deadline: .now() + deferDecisionInterval) { [weak self] in
                    guard let self = self else { return }
                    let desired = self.onPreAlphabetInputDecide?()
                    if let desiredMode = desired, let ime = self.imeController {
                        // Anti-flap: avoid switching back within short window
                        if let lastAt = self.lastProgSwitchAt, let lastMode = self.lastProgSwitchMode,
                           lastMode != desiredMode, Date().timeIntervalSince(lastAt) < self.antiFlapWindow {
                            // Do not switch back; just inject with current mode
                        } else {
                        let current = ime.getCurrentInputMode()
                        if current != desiredMode {
                            ime.switchToInputMode(desiredMode)
                            if desiredMode == .japanese {
                                self.jpSessionActive = true
                                self.jpSessionCount = max(1, self.jpSessionCount + 1)
                                self.canceledJPHoldUntil = nil
                            } else {
                                self.jpSessionActive = false
                                self.jpSessionCount = 0
                                self.canceledJPHoldUntil = nil
                            }
                            self.lastProgSwitchMode = desiredMode
                            self.lastProgSwitchAt = Date()
                        }
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
                    // Prefer responsiveness: allow immediate switch
                    lastCheckTime = now
                    ime.switchToInputMode(desiredMode)
                    if desiredMode == .japanese {
                        jpSessionActive = true
                        jpSessionCount = max(1, jpSessionCount + 1)
                        canceledJPHoldUntil = nil
                    } else {
                        jpSessionActive = false
                        jpSessionCount = 0
                        canceledJPHoldUntil = nil
                    }
                    lastProgSwitchMode = desiredMode
                    lastProgSwitchAt = now
                    postSyntheticKey(keyCode: keyCode, flags: flags, keyDown: true)
                    postSyntheticKey(keyCode: keyCode, flags: flags, keyDown: false)
                    suppressNextKeyUpForKeyCodes.insert(keyCode)
                    DispatchQueue.main.async { [weak self] in self?.onAlphabetInput?() }
                    return true
                }
                // If already JP and desired JP, mark session as active
                if desiredMode == .japanese {
                    jpSessionActive = true
                    jpSessionCount &+= 1
                }
            }

            // Otherwise, apply throttle just for logging/diagnostics
            if let lastCheck = lastCheckTime {
                let elapsed = now.timeIntervalSince(lastCheck)
                if elapsed < throttleInterval { return false }
            }
            if let lastIMEChange = imeController?.lastInputSourceChangeTime {
                let elapsed = now.timeIntervalSince(lastIMEChange)
                if elapsed < throttleInterval { return false }
            }

            lastCheckTime = now
            DispatchQueue.main.async { [weak self] in self?.onAlphabetInput?() }
            return false
        }

        // Backspace handling: decrease JP session count, possibly end session
        if type == .keyDown && isBackspace(keyCode: keyCode) {
            if hasModifiers {
                // Modified backspace (Option/Command) → likely larger deletion; end session
                jpSessionActive = false
                jpSessionCount = 0
                canceledJPHoldUntil = Date().addingTimeInterval(0.6)
            } else {
                if jpSessionCount > 0 { jpSessionCount &-= 1 }
                if jpSessionCount == 0 { jpSessionActive = false; canceledJPHoldUntil = Date().addingTimeInterval(0.6) }
            }
        }

        // Also record Japanese layout textual keys (approximation):
        // while in JP mode, any non-modifier, non-navigation, non-commit, non-space keyDown
        // is considered textual and updates lastUserTypingTime
        if type == .keyDown, let ime = imeController, ime.getCurrentInputMode() == .japanese {
            if !hasModifiers && !isNavigationKey(keyCode: keyCode) && !isCommitKey(keyCode: keyCode) && !isSpace(keyCode: keyCode) {
                lastUserTypingTime = Date()
            }
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

    private func isSpace(keyCode: Int64) -> Bool { keyCode == 49 }
    private func isBackspace(keyCode: Int64) -> Bool { keyCode == 51 }
    private func isCommitKey(keyCode: Int64) -> Bool { keyCode == 36 || keyCode == 76 || keyCode == 53 }

    // External check from App logic
    func isCompositionHoldActive() -> Bool {
        if let until = compositionHoldUntil { return Date() < until }
        return false
    }

    func isSpacePressed() -> Bool { spacePressed }

    func didNavigateRecently(within: TimeInterval = 0.25) -> Bool {
        if let t = lastNavigationTime { return Date().timeIntervalSince(t) < within }
        return false
    }

    func isJPSessionActive() -> Bool { jpSessionActive }

    func isCanceledJPHoldActive() -> Bool {
        if let t = canceledJPHoldUntil { return Date() < t }
        return false
    }

    private func isRunLockBlocking(_ desired: IMEController.InputMode) -> Bool {
        if let mode = runLockMode, let until = runLockUntil, Date() < until {
            return mode != desired
        }
        return false
    }

    deinit {
        stopMonitoring()
    }
}
