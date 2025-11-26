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
    // Count consecutive ASCII letter characters before the cursor
    private var asciiStreak: Int = 0
    private var autoSwitchEnabled: Bool = true {
        didSet {
            UserDefaults.standard.set(autoSwitchEnabled, forKey: "AutoSwitchEnabled")
            updateStatusItemIcon()
        }
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

            return
        }

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

        // Initialize manager and controller
        manager = AccessibilityManager()
        imeController = IMEController()

        // デバッグ: 利用可能な入力ソースを表示
        imeController?.listAvailableInputSources()
        print()

        // Start monitoring IME changes
        imeController?.startMonitoringInputSourceChanges()

        // Initialize keyboard monitor
        keyboardMonitor = KeyboardMonitor()
        keyboardMonitor?.imeController = imeController
        // Decide desired mode before delivering the keystroke
        keyboardMonitor?.onPreAlphabetInputDecide = { [weak self] in
            return self?.decideDesiredMode()
        }
        // Optional: keep async logging/diagnostics
        keyboardMonitor?.onAlphabetInput = { [weak self] in
            self?.handleAlphabetInput()
        }
        keyboardMonitor?.onAlphabetKey = { key in
            print("⌨️ Key: '\(key)'")
        }

        // Start keyboard monitoring
        keyboardMonitor?.startMonitoring()

        // Register login item helper to keep IMK resident
        enableLoginItem()
    }

    private func updateStatusItemIcon() {
        if let button = statusItem?.button {
            button.title = autoSwitchEnabled ? "🔄" : "⏸"
        }
    }

    // Decide desired mode (called from event tap thread)
    private func decideDesiredMode() -> IMEController.InputMode? {
        guard let manager = manager else { return nil }
        if !autoSwitchEnabled { return nil }
        let composing = manager.isComposing()
        var summaryPos: Int = -1
        var summaryPrev: Character? = nil
        var summarySession = (keyboardMonitor?.isJPSessionActive() == true)
        var summarySpace = (imeController?.getCurrentInputMode() == .japanese) && (keyboardMonitor?.isSpacePressed() == true)
        func log(_ result: IMEController.InputMode?, _ reason: String) {
            let p = summaryPrev.map { String($0).debugDescription } ?? "(none)"
            let res = result == nil ? "nil" : (result == .some(.japanese) ? "JP" : "EN")
            print("[decide] pos=\(summaryPos) prev=\(p) compose=\(composing) session=\(summarySession) space=\(summarySpace) → \(res) reason=\(reason)")
        }
        // Respect real user-initiated toggle: short grace window only
        if let ime = imeController, ime.isRecentUserToggle(grace: 0.3) {
            log(nil, "userToggle"); return nil
        }
        if composing { log(nil, "compose"); return nil }

        if let ctx = manager.getContextInfo() {
            summaryPos = ctx.cursorPosition; summaryPrev = ctx.left
            if ctx.cursorPosition == 0 { log(nil, "head"); return nil }
            if let prev = ctx.left {
                // If just after newline, do not force switch
                if let sc = String(prev).unicodeScalars.first, (sc.value == 0x0A || sc.value == 0x0D) { log(nil, "newline"); return nil }
                // ORDER: prev ASCII -> EN (takes precedence over session/hold/space)
                if let sc = String(prev).unicodeScalars.first, sc.isASCII && (CharacterSet.letters.contains(sc) || CharacterSet.decimalDigits.contains(sc)) {
                    // When currently in JP mode, only allow EN flip if user likely changed context
                    if let current = imeController?.getCurrentInputMode(), current == .japanese {
                        var allowEN = false
                        let now = Date()
                        if keyboardMonitor?.didNavigateRecently(within: 0.3) == true {
                            allowEN = true
                        } else if let t = keyboardMonitor?.lastUserTypingTime, now.timeIntervalSince(t) > 0.2 {
                            // small idle gap suggests intentional context change (e.g., click or pause)
                            allowEN = true
                        }
                        if !allowEN { log(nil, "jpTyping"); return nil }
                    }
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
                    // Optional stability check only if we are about to actively switch
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
        if let info = manager.getDetailedInfo() {
            summaryPos = info.cursorPosition; summaryPrev = info.characterBefore
            if info.cursorPosition == 0 { log(nil, "head"); return nil }
            if let prev = info.characterBefore, let s = String(prev).unicodeScalars.first, (s.value == 0x0A || s.value == 0x0D) { log(nil, "newline"); return nil }
            if let prev = info.characterBefore {
                if let sc = String(prev).unicodeScalars.first, sc.isASCII && (CharacterSet.letters.contains(sc) || CharacterSet.decimalDigits.contains(sc)) {
                    // When currently in JP mode, only allow EN flip if user likely changed context
                    if let current = imeController?.getCurrentInputMode(), current == .japanese {
                        var allowEN = false
                        let now = Date()
                        if keyboardMonitor?.didNavigateRecently(within: 0.3) == true {
                            allowEN = true
                        } else if let t = keyboardMonitor?.lastUserTypingTime, now.timeIntervalSince(t) > 0.2 {
                            allowEN = true
                        }
                        if !allowEN { log(nil, "jpTyping"); return nil }
                    }
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

    @objc private func switchToJP() {
        imeController?.markUserToggle()
        imeController?.switchToInputMode(.japanese)
    }

    @objc private func switchToEN() {
        imeController?.markUserToggle()
        imeController?.switchToInputMode(.english)
    }

    @objc func quit() {
        NSApplication.shared.terminate(nil)
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
