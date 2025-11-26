//
//  FlowIMEApp.swift
//  FlowIME
//
//  Created by taro hirose on 2025/11/25.
//

import SwiftUI
import AppKit
import ServiceManagement

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
            button.title = "🔄"
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

        // Start keyboard monitoring
        keyboardMonitor?.startMonitoring()

        // Register login item helper to keep IMK resident
        enableLoginItem()
    }

    // Decide desired mode (called from event tap thread)
    private func decideDesiredMode() -> IMEController.InputMode? {
        guard let manager = manager else { return nil }
        if manager.isComposing() { return nil }
        if let ctx = manager.getContextInfo() {
            if ctx.cursorPosition == 0 { return nil }
            // Strong right-side English context: prefer English immediately
            if let right = ctx.right, let rsc = String(right).unicodeScalars.first,
               rsc.isASCII && (CharacterSet.letters.contains(rsc) || CharacterSet.decimalDigits.contains(rsc)) {
                return .english
            }
            if keyboardMonitor?.isJPSessionActive() == true { return nil }
            if keyboardMonitor?.isCompositionHoldActive() == true { return nil }
            if imeController?.getCurrentInputMode() == .japanese, keyboardMonitor?.isSpacePressed() == true { return nil }
            if let prev = ctx.left {
                // If just after newline, do not force switch
                if let sc = String(prev).unicodeScalars.first, (sc.value == 0x0A || sc.value == 0x0D) { return nil }
                if isJapanese(prev) { return .japanese }
                if let sc = String(prev).unicodeScalars.first, sc.isASCII && (CharacterSet.letters.contains(sc) || CharacterSet.decimalDigits.contains(sc)) { return .english }
            }
            return nil
        }
        if let info = manager.getDetailedInfo() {
            if info.cursorPosition == 0 { return nil }
            if let prev = info.characterBefore, let s = String(prev).unicodeScalars.first, (s.value == 0x0A || s.value == 0x0D) { return nil }
            // Strong right-side English context: prefer English immediately (fallback path)
            if let right = info.characterAfter, let rsc = String(right).unicodeScalars.first,
               rsc.isASCII && (CharacterSet.letters.contains(rsc) || CharacterSet.decimalDigits.contains(rsc)) {
                return .english
            }
            if keyboardMonitor?.isJPSessionActive() == true { return nil }
            if keyboardMonitor?.isCompositionHoldActive() == true { return nil }
            if imeController?.getCurrentInputMode() == .japanese, keyboardMonitor?.isSpacePressed() == true { return nil }
            if let prev = info.characterBefore {
                if isJapanese(prev) { return .japanese }
                if let sc = String(prev).unicodeScalars.first, sc.isASCII && (CharacterSet.letters.contains(sc) || CharacterSet.decimalDigits.contains(sc)) { return .english }
            }
        }
        return nil
    }

    private func enableLoginItem() {
        // The helper must be embedded as a Login Item with this identifier
        let helperID = "com.flowime.inputmethod.FlowIMEHelper"
        do {
            try SMAppService.loginItem(identifier: helperID).register()
            print("✅ Login item registered: \(helperID)")
        } catch {
            print("⚠️ Login item register failed: \(error)")
        }
    }

    func handleAlphabetInput() {
        guard let manager = manager, let imeController = imeController else { return }

        // 前の文字を取得
        if let ctx = manager.getContextInfo() {
            print("─────────────────────────────────────────────────")
            print("🎯 Alphabet key detected!")
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

        if AccessibilityManager.checkAccessibilityPermissions() {
            menu.addItem(NSMenuItem(title: "✅ IME Auto-Switching Active", action: nil, keyEquivalent: ""))
        } else {
            menu.addItem(NSMenuItem(title: "⚠️ No Permissions", action: nil, keyEquivalent: ""))
        }

        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
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
