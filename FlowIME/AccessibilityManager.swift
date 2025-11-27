//
//  AccessibilityManager.swift
//  FlowIME
//
//  Created by Claude Code
//ko

import Cocoa
@preconcurrency import ApplicationServices

// Some AX attribute constants are not exposed as symbols in Swift headers.
// Define the raw string for marked text range explicitly.
private let AXMarkedTextRangeAttributeName: CFString = "AXMarkedTextRange" as CFString

class AccessibilityManager {
    private var observer: AXObserver?
    private var currentObservedElement: AXUIElement?
    private var lastObservedPosition: Int?

    // Callback when selection (cursor position) changes
    var onSelectionChanged: (() -> Void)?

    /// Check if the app has accessibility permissions
    static func checkAccessibilityPermissions() -> Bool {
        return AXIsProcessTrusted()
    }

    /// Lightweight context: cursor position and neighbor characters only
    func getContextInfo() -> (cursorPosition: Int, left: Character?, right: Character?)? {
        guard let element = getFocusedElement() else { return nil }

        // 1) Get selection range (cursor position)
        var rangeValue: AnyObject?
        let res = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue)
        guard res == .success, let any = rangeValue else { return nil }
        let axVal = any as! AXValue
        var cfRange = CFRange()
        guard AXValueGetValue(axVal, .cfRange, &cfRange) else { return nil }
        let pos = cfRange.location

        // Helper to fetch 1 char string via parameterized attribute
        func fetchChar(at location: Int) -> Character? {
            let paramAttr: CFString = "AXStringForRange" as CFString
            var tmpRange = CFRange(location: location, length: 1)
            guard let paramAX = AXValueCreate(.cfRange, &tmpRange) else { return nil }
            var result: AnyObject?
            let r = AXUIElementCopyParameterizedAttributeValue(element, paramAttr, paramAX, &result)
            if r == .success, let s = result as? String, let ch = s.first { return ch }
            return nil
        }

        // Try left and right without reading entire text
        let left: Character? = pos > 0 ? fetchChar(at: pos - 1) : nil
        // We do not fetch right char for pos at end; best effort
        let right: Character? = fetchChar(at: pos)

        return (cursorPosition: pos, left: left, right: right)
    }
    /// Check if there is active IME composition (marked text present)
    func isComposing() -> Bool {
        guard let element = getFocusedElement() else { return false }
        var markedValue: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, AXMarkedTextRangeAttributeName, &markedValue)
        guard result == .success, let any = markedValue else { return false }
        let axValue = any as! AXValue
        var range = CFRange()
        if AXValueGetValue(axValue, .cfRange, &range) {
            return range.length > 0
        }
        return false
    }

    /// Request accessibility permissions with prompt
    @MainActor
    static func requestAccessibilityPermissions() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as CFString
        let options = [key: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    /// Get the currently focused UI element
    func getFocusedElement(verbose: Bool = false) -> AXUIElement? {
        // Get the system-wide accessibility object
        let systemWide = AXUIElementCreateSystemWide()

        // Get the focused element
        var focusedApp: AnyObject?
        let appResult = AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focusedApp)

        if verbose {
            print("      [DEBUG] App result: \(appResult.rawValue)")
        }

        guard appResult == .success, let app = focusedApp else {
            if verbose {
                print("      [DEBUG] Failed to get focused app")
            }
            return nil
        }

        // Get app name for debugging
        if verbose {
            var appName: AnyObject?
            let nameResult = AXUIElementCopyAttributeValue(app as! AXUIElement, kAXTitleAttribute as CFString, &appName)
            if nameResult == .success, let name = appName as? String {
                print("      [DEBUG] Focused app: \(name)")
            }
        }

        // Get the focused element from the app
        var focusedElement: AnyObject?
        let elementResult = AXUIElementCopyAttributeValue(app as! AXUIElement, kAXFocusedUIElementAttribute as CFString, &focusedElement)

        if verbose {
            print("      [DEBUG] Element result: \(elementResult.rawValue)")
        }

        guard elementResult == .success else {
            if verbose {
                print("      [DEBUG] Failed to get focused element")
            }
            return nil
        }

        // Get element role for debugging
        if verbose {
            var role: AnyObject?
            let roleResult = AXUIElementCopyAttributeValue(focusedElement as! AXUIElement, kAXRoleAttribute as CFString, &role)
            if roleResult == .success, let roleStr = role as? String {
                print("      [DEBUG] Element role: \(roleStr)")
            }
        }

        return (focusedElement as! AXUIElement)
    }

    /// Get the text content from a UI element
    func getTextContent(from element: AXUIElement) -> String? {
        var value: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value)

        guard result == .success else {
            return nil
        }

        return value as? String
    }

    /// Get the selected text range (cursor position)
    func getSelectedTextRange(from element: AXUIElement) -> CFRange? {
        var rangeValue: AnyObject?
        let result = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeValue)

        guard result == .success, let value = rangeValue else {
            return nil
        }

        // Extract CFRange from AXValue
        var range = CFRange()
        let success = AXValueGetValue(value as! AXValue, .cfRange, &range)

        guard success else {
            return nil
        }

        return range
    }

    /// Get the character immediately before the cursor
    func getCharacterBeforeCursor() -> Character? {
        guard let element = getFocusedElement() else {
            print("No focused element found")
            return nil
        }

        guard let text = getTextContent(from: element) else {
            print("No text content found")
            return nil
        }

        guard let range = getSelectedTextRange(from: element) else {
            print("No selection range found")
            return nil
        }

        let cursorPosition = range.location

        // Check if cursor is at the beginning
        guard cursorPosition > 0 else {
            print("Cursor is at the beginning")
            return nil
        }

        // Check if cursor position is valid
        guard cursorPosition <= text.count else {
            print("Invalid cursor position: \(cursorPosition) (text length: \(text.count))")
            return nil
        }

        // Get the character before cursor
        let index = text.index(text.startIndex, offsetBy: cursorPosition - 1)
        let character = text[index]

        return character
    }

    /// Get detailed information about the current text field state
    func getDetailedInfo() -> (text: String, cursorPosition: Int, characterBefore: Character?, characterAfter: Character?)? {
        guard let element = getFocusedElement() else {
            return nil
        }

        guard let text = getTextContent(from: element) else {
            return nil
        }

        guard let range = getSelectedTextRange(from: element) else {
            return nil
        }

        let cursorPosition = range.location

        // Get character before cursor if available
        var characterBefore: Character?
        var characterAfter: Character?
        if cursorPosition > 0 && cursorPosition <= text.count {
            let index = text.index(text.startIndex, offsetBy: cursorPosition - 1)
            characterBefore = text[index]
        }
        if cursorPosition < text.count {
            let index = text.index(text.startIndex, offsetBy: cursorPosition)
            characterAfter = text[index]
        }

        return (text: text, cursorPosition: cursorPosition, characterBefore: characterBefore, characterAfter: characterAfter)
    }

    // MARK: - AXObserver for cursor movement detection

    /// Start observing cursor position changes on the currently focused element
    func startObservingCursorChanges() {
        // Clean up existing observer
        stopObservingCursorChanges()

        guard let focusedElement = getFocusedElement() else {
            print("⚠️ [AXObserver] No focused element to observe")
            return
        }

        // Create observer for the current process
        var observerRef: AXObserver?
        let pid = ProcessInfo.processInfo.processIdentifier
        let result = AXObserverCreate(pid, axObserverCallback, &observerRef)

        guard result == .success, let observer = observerRef else {
            print("❌ [AXObserver] Failed to create observer: \(result.rawValue)")
            return
        }

        self.observer = observer
        self.currentObservedElement = focusedElement

        // Add observer to current run loop
        CFRunLoopAddSource(
            CFRunLoopGetCurrent(),
            AXObserverGetRunLoopSource(observer),
            .defaultMode
        )

        // Pass self pointer as user data (passUnretained is safe as long as observer is kept alive)
        let selfPtr = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        // Observe selection change notification
        let addResult = AXObserverAddNotification(
            observer,
            focusedElement,
            kAXSelectedTextChangedNotification as CFString,
            selfPtr
        )

        if addResult == .success {
            // Get initial position
            if let range = getSelectedTextRange(from: focusedElement) {
                lastObservedPosition = range.location
            }
            print("✅ [AXObserver] Started observing cursor changes")
        } else {
            print("❌ [AXObserver] Failed to add notification observer: \(addResult.rawValue)")
            stopObservingCursorChanges()
        }
    }

    /// Stop observing cursor position changes
    func stopObservingCursorChanges() {
        if let observer = observer, let element = currentObservedElement {
            AXObserverRemoveNotification(
                observer,
                element,
                kAXSelectedTextChangedNotification as CFString
            )

            CFRunLoopRemoveSource(
                CFRunLoopGetCurrent(),
                AXObserverGetRunLoopSource(observer),
                .defaultMode
            )
        }
        observer = nil
        currentObservedElement = nil
        lastObservedPosition = nil
    }

    /// Handle selection change notification
    fileprivate func handleSelectionChanged(element: AXUIElement) {
        guard let range = getSelectedTextRange(from: element) else { return }
        let newPosition = range.location

        // Only trigger callback if position actually changed
        if let lastPos = lastObservedPosition, lastPos != newPosition {
            print("📍 [AXObserver] Cursor moved: \(lastPos) → \(newPosition)")
            onSelectionChanged?()
        }

        lastObservedPosition = newPosition
    }

    /// Restart observation on the currently focused element (call after app/field focus change)
    func restartObserving() {
        startObservingCursorChanges()
    }

    deinit {
        stopObservingCursorChanges()
    }
}

// MARK: - AXObserver Callback

private func axObserverCallback(
    observer: AXObserver,
    element: AXUIElement,
    notification: CFString,
    userData: UnsafeMutableRawPointer?
) -> Void {
    guard let userData = userData else { return }
    let manager = Unmanaged<AccessibilityManager>.fromOpaque(userData).takeUnretainedValue()

    if notification as String == kAXSelectedTextChangedNotification as String {
        manager.handleSelectionChanged(element: element)
    }
}
