//
//  FlowIMEApp.swift
//  FlowIME
//
//  Created by taro hirose on 2025/11/25.
//

import SwiftUI
import AppKit
import ServiceManagement
import Darwin

@main
struct FlowIMEApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var manager: AccessibilityManager?
    var imeController: IMEController?
    var keyboardMonitor: KeyboardMonitor?
    // When true, a decision is being made due to a navigation event
    private var navDecisionActive: Bool = false
    private var engineStarted: Bool = false
    private var permissionTimer: Timer?
    private var settingsWindow: NSWindow?
    // Count consecutive ASCII letter characters before the cursor
    private var asciiStreak: Int = 0
    private var autoSwitchEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(autoSwitchEnabled, forKey: "AutoSwitchEnabled")
            updateStatusItemIcon()
        }
    }
    // User-adjustable idle gap to allow JP→EN when left is ASCII
    private let idleGapKey = "IdleGapForEN"
    private let defaultIdleGap: TimeInterval = 0.2
    private func currentIdleGap() -> TimeInterval {
        let ud = UserDefaults.standard
        if ud.object(forKey: idleGapKey) == nil { return defaultIdleGap }
        return ud.double(forKey: idleGapKey)
    }
    private func setIdleGap(_ seconds: TimeInterval) {
        UserDefaults.standard.set(seconds, forKey: idleGapKey)
    }

    private func appVersionString() -> String {
        let info = Bundle.main.infoDictionary
        let ver = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "v\(ver) (\(build))"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🚀 FlowIME \(appVersionString())")
        print(String(repeating: "=", count: 50))
        print()

        // Create menu bar item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem?.button {
            autoSwitchEnabled = UserDefaults.standard.object(forKey: "AutoSwitchEnabled") as? Bool ?? true
            button.title = autoSwitchEnabled ? "🔄" : "⏸"
            button.action = #selector(statusItemClicked)
            button.target = self
        }

        // Check accessibility permissions
        if !AccessibilityManager.checkAccessibilityPermissions() {
            print("⚠️  Accessibility permissions required!")
            print()
            print("📝 Steps to grant permission:")
            print("1. System Preferences > Security & Privacy > Privacy > Accessibility")
            print("2. Click the lock icon to make changes")
            print("3. Add and enable this app")
            print()
            print("🔄 Requesting permissions now...")

            Task { @MainActor in
                AccessibilityManager.requestAccessibilityPermissions()
            }

            // Show alert
            DispatchQueue.main.async {
                let alert = NSAlert()
                alert.messageText = "Accessibility Permissions Required"
                alert.informativeText = "FlowIME needs accessibility permissions to function.\n\nPlease go to:\nSystem Preferences > Security & Privacy > Privacy > Accessibility\n\nAdd FlowIME and enable it, then restart the app."
                alert.alertStyle = .warning
                alert.addButton(withTitle: "OK")
                alert.runModal()
            }

            // Live re-check: initialize automatically once permission is granted
            permissionTimer?.invalidate()
            permissionTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                if AccessibilityManager.checkAccessibilityPermissions() {
                    self.permissionTimer?.invalidate(); self.permissionTimer = nil
                    DispatchQueue.main.async { [weak self] in self?.startEngine() }
                }
            }
            return
        }
        startEngine()

        // Observe defaults changes to keep status icon in sync with Settings
        NotificationCenter.default.addObserver(self, selector: #selector(defaultsChanged), name: UserDefaults.didChangeNotification, object: nil)
    }

    private func updateStatusItemIcon() {
        if let button = statusItem?.button {
            button.title = autoSwitchEnabled ? "🔄" : "⏸"
        }
    }

    // Decide desired mode (called from event tap thread or nav-time)
    private func decideDesiredMode(trigger: String = "unknown") -> IMEController.InputMode? {
        guard let manager = manager else { return nil }
        if !autoSwitchEnabled { return nil }
        if keyboardMonitor?.isDecisionGateEnabled() == false && !navDecisionActive {
            print("[decide:\(trigger)] pos=-1 prev=(none) compose=\(manager.isComposing()) session=\(keyboardMonitor?.isJPSessionActive() == true) space=\((imeController?.getCurrentInputMode() == .japanese) && (keyboardMonitor?.isSpacePressed() == true)) → nil reason=gateOff")
            return nil
        }
        let composing = manager.isComposing()
        var summaryPos: Int = -1
        var summaryPrev: Character? = nil
        var summarySession = (keyboardMonitor?.isJPSessionActive() == true)
        var summarySpace = (imeController?.getCurrentInputMode() == .japanese) && (keyboardMonitor?.isSpacePressed() == true)
        func log(_ result: IMEController.InputMode?, _ reason: String) {
            let p = summaryPrev.map { String($0).debugDescription } ?? "(none)"
            let res = result == nil ? "nil" : (result == .some(.japanese) ? "JP" : "EN")
            print("[decide:\(trigger)] pos=\(summaryPos) prev=\(p) compose=\(composing) session=\(summarySession) space=\(summarySpace) → \(res) reason=\(reason)")
        }
        // Respect real user-initiated toggle: short grace window only
        if let ime = imeController, ime.isRecentUserToggle(grace: 0.3) {
            log(nil, "userToggle"); return nil
        }
        if composing { log(nil, "compose"); return nil }

        if let ctxRaw = manager.getContextInfo() {
            let ctx = ctxRaw
            summaryPos = ctx.cursorPosition; summaryPrev = ctx.left
            // Workaround for invalid gigantic positions
            if ctx.cursorPosition >= 1_000_000 {
                // fall through to detailed path below
            } else {
                if ctx.cursorPosition == 0 {
                    // At head: only allow nav-time right-char peek
                    if navDecisionActive {
                        if let r = ctx.right {
                            if let sc = String(r).unicodeScalars.first, sc.isASCII && (CharacterSet.letters.contains(sc) || CharacterSet.decimalDigits.contains(sc)) { log(.english, "rightEN"); return .english }
                            if isJapanese(r) { log(.japanese, "rightJP"); return .japanese }
                        }
                    }
                    log(nil, "head"); return nil
                }
                if let prev = ctx.left {
                    // If just after newline, allow right-char peek only for nav-time
                    if let sc0 = String(prev).unicodeScalars.first, (sc0.value == 0x0A || sc0.value == 0x0D) {
                        if navDecisionActive, let r = ctx.right {
                            if let sc = String(r).unicodeScalars.first, sc.isASCII && (CharacterSet.letters.contains(sc) || CharacterSet.decimalDigits.contains(sc)) { log(.english, "rightEN"); return .english }
                            if isJapanese(r) { log(.japanese, "rightJP"); return .japanese }
                        }
                        log(nil, "newline"); return nil
                    }
                    // ORDER: prev ASCII -> EN
                    if let sc = String(prev).unicodeScalars.first, sc.isASCII && (CharacterSet.letters.contains(sc) || CharacterSet.decimalDigits.contains(sc)) {
                        // Guard against AX timing glitch: confirm the same left-char twice quickly
                        usleep(7000) // ~7ms
                        if let ctx2 = manager.getContextInfo(), ctx2.cursorPosition == ctx.cursorPosition, ctx2.left == ctx.left {
                            log(.english, "prevEN"); return .english
                        } else {
                            log(nil, "unstable"); return nil
                        }
                    }
                    // Then prev JP -> JP
                    if isJapanese(prev) {
                        if let current = imeController?.getCurrentInputMode(), current != .japanese {
                            usleep(7000)
                            if let ctx2 = manager.getContextInfo(), ctx2.cursorPosition == ctx.cursorPosition, ctx2.left == ctx.left {
                                log(.japanese, "prevJP"); return .japanese
                            } else {
                                log(nil, "unstable"); return nil
                            }
                        } else {
                            log(.japanese, "prevJP"); return .japanese
                        }
                    }
                }
                // Finally suppressions for neutral cases
                if keyboardMonitor?.isJPSessionActive() == true { log(nil, "session"); return nil }
                if keyboardMonitor?.isCompositionHoldActive() == true { log(nil, "hold"); return nil }
                if (imeController?.getCurrentInputMode() == .japanese) && (keyboardMonitor?.isSpacePressed() == true) { log(nil, "space"); return nil }
                log(nil, "neutral"); return nil
            }
        }
        if let info = manager.getDetailedInfo() {
            summaryPos = info.cursorPosition; summaryPrev = info.characterBefore
            if info.cursorPosition == 0 {
                if navDecisionActive, let r = info.characterAfter {
                    if let sc = String(r).unicodeScalars.first, sc.isASCII && (CharacterSet.letters.contains(sc) || CharacterSet.decimalDigits.contains(sc)) { log(.english, "rightEN"); return .english }
                    if isJapanese(r) { log(.japanese, "rightJP"); return .japanese }
                }
                log(nil, "head"); return nil
            }
            if let prev = info.characterBefore, let s = String(prev).unicodeScalars.first, (s.value == 0x0A || s.value == 0x0D) {
                if navDecisionActive, let r = info.characterAfter {
                    if let sc = String(r).unicodeScalars.first, sc.isASCII && (CharacterSet.letters.contains(sc) || CharacterSet.decimalDigits.contains(sc)) { log(.english, "rightEN"); return .english }
                    if isJapanese(r) { log(.japanese, "rightJP"); return .japanese }
                }
                log(nil, "newline"); return nil
            }
            if let prev = info.characterBefore {
                if let sc = String(prev).unicodeScalars.first, sc.isASCII && (CharacterSet.letters.contains(sc) || CharacterSet.decimalDigits.contains(sc)) {
                    // Fallback path also honors stability
                    usleep(7000)
                    if let info2 = manager.getDetailedInfo(), info2.cursorPosition == info.cursorPosition, info2.characterBefore == info.characterBefore {
                        log(.english, "prevEN"); return .english
                    } else {
                        log(nil, "unstable"); return nil
                    }
                }
                if isJapanese(prev) {
                    if let current = imeController?.getCurrentInputMode(), current != .japanese {
                        usleep(7000)
                        if let info2 = manager.getDetailedInfo(), info2.cursorPosition == info.cursorPosition, info2.characterBefore == info.characterBefore {
                            log(.japanese, "prevJP"); return .japanese
                        } else {
                            log(nil, "unstable"); return nil
                        }
                    } else {
                        log(.japanese, "prevJP"); return .japanese
                    }
                }
            }
            if keyboardMonitor?.isJPSessionActive() == true { log(nil, "session"); return nil }
            if keyboardMonitor?.isCompositionHoldActive() == true { log(nil, "hold"); return nil }
            if (imeController?.getCurrentInputMode() == .japanese) && (keyboardMonitor?.isSpacePressed() == true) { log(nil, "space"); return nil }
            log(nil, "neutral"); return nil
        }
        return nil
    }

    private func enableLoginItem() {
        // Resolve embedded helper's bundle identifier dynamically to avoid mismatch
        let helperID: String = {
            let helperURL = Bundle.main.bundleURL
                .appendingPathComponent("Contents/Library/LoginItems/FlowIMEHelper.app", isDirectory: true)
            let infoURL = helperURL.appendingPathComponent("Contents/Info.plist")
            if let dict = NSDictionary(contentsOf: infoURL),
               let id = dict["CFBundleIdentifier"] as? String, !id.isEmpty {
                return id
            }
            // Fallbacks (older hardcoded IDs)
            return "com.flowime.inputmethod.FlowIMEHelper"
        }()
        do {
            try SMAppService.loginItem(identifier: helperID).register()
            print("✅ Login item registered: \(helperID)")
        } catch {
            print("⚠️ Login item register failed: \(error) id=\(helperID)")
            print("ℹ️ Check: FlowIME.app/Contents/Library/LoginItems/FlowIMEHelper.app exists and IDs match.")
        }
    }

    func handleAlphabetInput() {
        guard let manager = manager, let imeController = imeController else { return }

        // 前の文字を取得
        if let ctx = manager.getContextInfo() {
            print("🎯 Alphabet key detected! (post)")
            print("📍 Cursor position: \(ctx.cursorPosition)")
            if let ch = ctx.left {
                print("✨ Character before cursor: \(String(ch).debugDescription)")
                // Diagnostic only: switching is handled in the pre-event path
            } else {
                print("⬜️ Character before cursor: (none)")
            }
        }
    }

    @objc func statusItemClicked() {
        let menu = NSMenu()

        menu.addItem(NSMenuItem(title: "FlowIME \(appVersionString())", action: nil, keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())

        let toggle = NSMenuItem(title: "Auto Switch", action: #selector(toggleAutoSwitch), keyEquivalent: "")
        toggle.state = autoSwitchEnabled ? .on : .off
        toggle.target = self
        menu.addItem(toggle)

        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)

        // EN Idle Gap submenu (JP→EN許可の小休止しきい値)
        let idleParent = NSMenuItem(title: "EN Idle Gap", action: nil, keyEquivalent: "")
        let idleMenu = NSMenu()
        let options: [(String, TimeInterval)] = [
            ("Off", 0.0), ("0.10s", 0.10), ("0.15s", 0.15), ("0.20s (default)", 0.20), ("0.30s", 0.30), ("0.40s", 0.40), ("0.50s", 0.50)
        ]
        let cur = currentIdleGap()
        for (title, value) in options {
            let it = NSMenuItem(title: title, action: #selector(setIdleGapFromMenu(_:)), keyEquivalent: "")
            it.target = self
            it.representedObject = value
            if (value == 0.0 && cur <= 0.0001) || abs(cur - value) < 0.0001 { it.state = .on }
            idleMenu.addItem(it)
        }
        idleParent.submenu = idleMenu
        menu.addItem(idleParent)

        menu.addItem(NSMenuItem.separator())

        let jp = NSMenuItem(title: "Switch to Japanese", action: #selector(switchToJP), keyEquivalent: "")
        jp.target = self
        menu.addItem(jp)
        let en = NSMenuItem(title: "Switch to English", action: #selector(switchToEN), keyEquivalent: "")
        en.target = self
        menu.addItem(en)

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    @objc private func toggleAutoSwitch() {
        autoSwitchEnabled.toggle()
    }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let hosting = NSHostingView(rootView: SettingsView())
            let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 300),
                               styleMask: [.titled, .closable],
                               backing: .buffered, defer: false)
            win.title = "FlowIME Settings"
            win.contentView = hosting
            settingsWindow = win
        }
        settingsWindow?.center()
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func switchToJP() {
        imeController?.markUserToggle()
        imeController?.switchToInputMode(.japanese)
    }

    @objc private func switchToEN() {
        imeController?.markUserToggle()
        imeController?.switchToInputMode(.english)
    }

    @objc private func setIdleGapFromMenu(_ sender: NSMenuItem) {
        if let v = sender.representedObject as? TimeInterval {
            setIdleGap(v)
        }
    }

    @objc func quit() {
        NSApplication.shared.terminate(nil)
    }

    @objc private func appDidActivate(_ note: Notification) {
        // Treat as a navigation event for the next key and run nav-time decision
        keyboardMonitor?.markExternalNavigation()
        keyboardMonitor?.enableDecisionGate()
        scheduleNavDecide(trigger: "app-switch")
        // Restart observer for the newly focused element
        manager?.restartObserving()
    }

    @objc private func defaultsChanged() {
        // Pull latest AutoSwitchEnabled and update icon
        let enabled = UserDefaults.standard.object(forKey: "AutoSwitchEnabled") as? Bool ?? true
        if enabled != autoSwitchEnabled {
            autoSwitchEnabled = enabled
        } else {
            updateStatusItemIcon()
        }
    }

    // Trigger a one-shot decision shortly after navigation so AX is up-to-date
    private func scheduleNavDecide(delay: TimeInterval = 0.08, trigger: String = "nav-time") {
        func attempt(_ remaining: Int, after: TimeInterval) {
            DispatchQueue.main.asyncAfter(deadline: .now() + after) { [weak self] in
                guard let self = self, self.autoSwitchEnabled else { return }
                guard let ime = self.imeController else { return }
                self.navDecisionActive = true
                let desired = self.decideDesiredMode(trigger: trigger)
                self.navDecisionActive = false
                guard let desiredMode = desired else {
                    if remaining > 0 { attempt(remaining - 1, after: 0.06) }
                    return
                }
                let current = ime.getCurrentInputMode()
                if current != desiredMode {
                    ime.switchToInputMode(desiredMode)
                    ime.enforceDesiredMode(desiredMode, duration: 0.4)
                }
                if desiredMode == .japanese { self.keyboardMonitor?.disableDecisionGate() }
                else { self.keyboardMonitor?.enableDecisionGate() }
            }
        }
        // Try up to 3 times to allow caret to settle after vertical moves
        attempt(2, after: delay)
    }

    // MARK: - Engine bootstrap (idempotent)
    private func startEngine() {
        if engineStarted { return }
        engineStarted = true

        print("✅ Accessibility permissions granted!")
        print()
        print("📊 IME Auto-Switching Active (Keyboard Input Mode)")
        print("💡 Type alphabet characters in any application")
        print("🔍 IME will automatically switch based on the previous character")
        print("   - Japanese character → IME ON")
        print("   - English/Number → IME OFF")
        print("⚡ Throttled: First key triggers check, then 1 second cooldown")
        print()
        print(String(repeating: "=", count: 50))
        print()

        manager = AccessibilityManager()
        imeController = IMEController()

        imeController?.listAvailableInputSources()
        print()

        imeController?.startMonitoringInputSourceChanges()
        imeController?.onInputSourceChanged = { [weak self] mode, programmatic in
            guard let self = self else { return }
            if mode == .japanese {
                self.keyboardMonitor?.markJPSwitchPendingLock()
            }
        }

        keyboardMonitor = KeyboardMonitor()
        keyboardMonitor?.imeController = imeController
        keyboardMonitor?.onPreAlphabetInputDecide = { [weak self] in
            return self?.decideDesiredMode(trigger: "pre-key")
        }
        keyboardMonitor?.onAlphabetInput = { [weak self] in
            self?.handleAlphabetInput()
        }
        keyboardMonitor?.onAlphabetKey = { key in
            print("⌨️ Key: '\(key)'")
        }
        // Setup navigation callback from KeyboardMonitor
        keyboardMonitor?.onNavigationEvent = { [weak self] in
            self?.scheduleNavDecide(trigger: "key-nav")
        }
        keyboardMonitor?.startMonitoring()

        // Setup AX cursor movement observer
        manager?.onSelectionChanged = { [weak self] in
            guard let self = self else { return }
            // Treat cursor movement as navigation
            self.keyboardMonitor?.markExternalNavigation()
            self.keyboardMonitor?.enableDecisionGate()
            self.scheduleNavDecide(trigger: "AX-cursor")
        }
        manager?.startObservingCursorChanges()

        enableLoginItem()

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appDidActivate(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
    }

    // Helper function to detect Japanese characters
    func isJapanese(_ char: Character) -> Bool {
        guard let scalar = String(char).unicodeScalars.first else {
            return false
        }

        let value = scalar.value

        // Hiragana: U+3040 - U+309F
        if value >= 0x3040 && value <= 0x309F {
            return true
        }

        // Katakana: U+30A0 - U+30FF
        if value >= 0x30A0 && value <= 0x30FF {
            return true
        }

        // Kanji (CJK Unified Ideographs): U+4E00 - U+9FAF
        if value >= 0x4E00 && value <= 0x9FAF {
            return true
        }

        return false
    }
}
