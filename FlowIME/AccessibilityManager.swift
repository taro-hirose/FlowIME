//
//  AccessibilityManager.swift
//  FlowIME
//
//  Created by Claude Code
//

import Cocoa
@preconcurrency import ApplicationServices

// Some AX attribute constants are not exposed as symbols in Swift headers.
// Define the raw string for marked text range explicitly.
private let AXMarkedTextRangeAttributeName: CFString = "AXMarkedTextRange" as CFString

class AccessibilityManager {

    /// Check if the app has accessibility permissions
    static func checkAccessibilityPermissions() -> Bool {
        return AXIsProcessTrusted()
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
    func getDetailedInfo() -> (text: String, cursorPosition: Int, characterBefore: Character?)? {
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
        if cursorPosition > 0 && cursorPosition <= text.count {
            let index = text.index(text.startIndex, offsetBy: cursorPosition - 1)
            characterBefore = text[index]
        }

        return (text: text, cursorPosition: cursorPosition, characterBefore: characterBefore)
    }
}
