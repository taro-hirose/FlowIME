//
//  IMEController.swift
//  FlowIME
//
//  Created by Claude Code - Phase 3
//

import Cocoa
import Carbon

class IMEController {

    enum InputMode {
        case japanese
        case english
    }

    // 最後にIMEが切り替わった時刻
    private(set) var lastInputSourceChangeTime: Date?
    private(set) var lastUserInitiatedChangeTime: Date?
    private var programmaticChangeInProgress = false
    private var isMonitoringChanges = false

    /// 現在のIME状態を取得
    func getCurrentInputMode() -> InputMode? {
        guard let currentSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return nil
        }

        guard let sourceID = TISGetInputSourceProperty(currentSource, kTISPropertyInputSourceID) else {
            return nil
        }

        let id = Unmanaged<CFString>.fromOpaque(sourceID).takeUnretainedValue() as String

        if id.contains("Japanese") || id.contains("Kotoeri") || id.contains("Hiragana") {
            return .japanese
        } else {
            return .english
        }
    }

    /// IMEを切り替える
    func switchToInputMode(_ mode: InputMode) {
        let currentMode = getCurrentInputMode()

        // 既に同じモードなら何もしない
        if currentMode == mode {
            print("   ℹ️  Already in \(mode) mode")
            return
        }

        // 自動切り替えの場合も時刻を記録（手動と区別しない）
        lastInputSourceChangeTime = Date()
        programmaticChangeInProgress = true

        switch mode {
        case .japanese:
            switchToJapanese()
        case .english:
            switchToEnglish()
        }
    }

    /// 入力ソース変更の監視を開始
    func startMonitoringInputSourceChanges() {
        guard !isMonitoringChanges else { return }

        // Distributed notification centerで入力ソース変更を監視
        DistributedNotificationCenter.default().addObserver(
            self,
            selector: #selector(inputSourceChanged),
            name: NSNotification.Name(rawValue: kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil
        )

        isMonitoringChanges = true
        print("✅ Started monitoring input source changes")
    }

    /// 入力ソース変更の監視を停止
    func stopMonitoringInputSourceChanges() {
        guard isMonitoringChanges else { return }

        DistributedNotificationCenter.default().removeObserver(
            self,
            name: NSNotification.Name(rawValue: kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil
        )

        isMonitoringChanges = false
        print("🛑 Stopped monitoring input source changes")
    }

    @objc private func inputSourceChanged(_ notification: Notification) {
        lastInputSourceChangeTime = Date()
        if programmaticChangeInProgress {
            programmaticChangeInProgress = false
            print("🔄 Input source changed (programmatic)")
        } else {
            lastUserInitiatedChangeTime = Date()
            print("🔄 Input source changed (user/system)")
        }
    }

    // Mark an explicit user toggle detected via key combo
    func markUserToggle() {
        lastUserInitiatedChangeTime = Date()
    }

    func isRecentUserToggle(grace: TimeInterval) -> Bool {
        guard let t = lastUserInitiatedChangeTime else { return false }
        return Date().timeIntervalSince(t) < grace
    }

    /// 日本語IMEに切り替え
    private func switchToJapanese() {
        // 利用可能な入力ソースを取得
        guard let inputSources = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else {
            print("   ❌ Failed to get input sources")
            return
        }

        // 日本語IMEを探す
        for source in inputSources {
            guard let sourceID = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
                continue
            }

            let id = Unmanaged<CFString>.fromOpaque(sourceID).takeUnretainedValue() as String

            // com.apple.inputmethod.Kotoeri.Japanese または Hiragana を探す
            if id.contains("com.apple.inputmethod.Kotoeri") &&
               (id.contains("Japanese") || id.contains("Hiragana")) {
                let result = TISSelectInputSource(source)
                if result == noErr {
                    print("   ✅ Switched to Japanese IME (\(id))")
                } else {
                    print("   ❌ Failed to switch to Japanese IME: \(result)")
                }
                return
            }
        }

        print("   ⚠️  Japanese IME not found")
    }

    /// 英語入力に切り替え
    private func switchToEnglish() {
        // 利用可能な入力ソースを取得
        guard let inputSources = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else {
            print("   ❌ Failed to get input sources")
            return
        }

        // 英語キーボードを探す
        for source in inputSources {
            guard let sourceID = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else {
                continue
            }

            let id = Unmanaged<CFString>.fromOpaque(sourceID).takeUnretainedValue() as String

            // com.apple.keylayout.ABC または US を探す
            if id == "com.apple.keylayout.ABC" || id == "com.apple.keylayout.US" {
                let result = TISSelectInputSource(source)
                if result == noErr {
                    print("   ✅ Switched to English input (\(id))")
                } else {
                    print("   ❌ Failed to switch to English: \(result)")
                }
                return
            }
        }

        print("   ⚠️  English keyboard not found")
    }

    /// デバッグ: 利用可能な入力ソースを全て表示
    func listAvailableInputSources() {
        guard let inputSources = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else {
            print("Failed to get input sources")
            return
        }

        print("Available Input Sources:")
        for source in inputSources {
            if let sourceID = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) {
                let id = Unmanaged<CFString>.fromOpaque(sourceID).takeUnretainedValue() as String
                print("  - \(id)")
            }
        }
    }

    deinit {
        stopMonitoringInputSourceChanges()
    }
}
