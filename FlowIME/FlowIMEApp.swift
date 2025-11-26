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

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("🚀 FlowIME - Phase 3 Prototype")
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
        // Do not interfere during ongoing IME composition (marked text exists)
        if manager.isComposing() { return nil }
        if let info = manager.getDetailedInfo() {
            // If user paused sufficiently since last typing, prefer Japanese start
            if let last = keyboardMonitor?.lastUserAlphabetTime {
                let idle = Date().timeIntervalSince(last)
                if idle > 1.2 { return .japanese }
            } else {
                // No prior typing recorded in this session
                return .japanese
            }
            // 文頭（カーソル位置0）では日本語を優先
            if info.cursorPosition == 0 { return .japanese }

            if let char = info.characterBefore, let scalar = String(char).unicodeScalars.first {
                // 直前が改行/空白なら日本語を優先
                if CharacterSet.whitespacesAndNewlines.contains(scalar) { return .japanese }

                if CharacterSet.letters.contains(scalar) {
                    return isJapanese(char) ? .japanese : .english
                }
                if CharacterSet.decimalDigits.contains(scalar) {
                    return .english
                }
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
        if let info = manager.getDetailedInfo() {
            print("─────────────────────────────────────────────────")
            print("🎯 Alphabet key detected!")

            // テキストが長い場合は省略表示
            let displayText: String
            if info.text.count > 100 {
                let prefix = String(info.text.prefix(50))
                displayText = "\(prefix)... (total: \(info.text.count) chars)"
            } else {
                displayText = info.text
            }
            print("📝 Text: \"\(displayText)\"")
            print("📍 Cursor position: \(info.cursorPosition)")

            if let char = info.characterBefore {
                print("✨ Character before cursor: '\(char)'")

                // Analyze character type and switch IME
                let scalar = String(char).unicodeScalars.first!
                if CharacterSet.letters.contains(scalar) {
                    if isJapanese(char) {
                        print("🇯🇵 Type: Japanese → Switching to Japanese IME")
                        imeController.switchToInputMode(.japanese)
                    } else {
                        print("🔤 Type: English → Switching to English input")
                        imeController.switchToInputMode(.english)
                    }
                } else if CharacterSet.decimalDigits.contains(scalar) {
                    print("🔢 Type: Number → Switching to English input")
                    imeController.switchToInputMode(.english)
                } else {
                    // 空白、改行、記号などは何もしない（現在のIME状態を維持）
                    print("🔣 Type: Symbol/Whitespace/Newline → No change (keeping current IME state)")
                }
            } else {
                // 文頭や文字が取得できない場合も何もしない
                if info.cursorPosition == 0 {
                    print("⬜️ Character before cursor: (none - cursor at beginning) → No change")
                } else {
                    print("❌ Failed to get character (cursor at \(info.cursorPosition), text length: \(info.text.count)) → No change")
                }
            }
        }
    }

    @objc func statusItemClicked() {
        let menu = NSMenu()

        menu.addItem(NSMenuItem(title: "FlowIME - Phase 3", action: nil, keyEquivalent: ""))
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
