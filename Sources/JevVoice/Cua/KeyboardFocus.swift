import ApplicationServices
import AppKit
import CoreGraphics
import Foundation

enum KeyboardFocus {
    enum ReadBack: Equatable {
        case confirmed
        case missing
        case unobservable
    }

    static let textRoles: Set<String> = [
        "AXTextField",
        "AXTextArea",
        "AXComboBox",
        "AXSearchField",
        "AXWebArea",
    ]

    @MainActor
    static func bringToFront(pid: pid_t) async -> Bool {
        if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
            return true
        }
        guard let application = NSRunningApplication(processIdentifier: pid) else {
            return false
        }
        _ = application.activate(options: [.activateAllWindows])
        for _ in 0..<12 {
            if NSWorkspace.shared.frontmostApplication?.processIdentifier == pid {
                return true
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    static func focusedElement(pid: pid_t) -> (role: String, value: String?)? {
        let app = AXUIElementCreateApplication(pid)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            app,
            kAXFocusedUIElementAttribute as CFString,
            &raw
        ) == .success,
        let raw,
        CFGetTypeID(raw) == AXUIElementGetTypeID() else {
            return nil
        }
        let element = unsafeDowncast(raw, to: AXUIElement.self)
        var roleRaw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXRoleAttribute as CFString,
            &roleRaw
        ) == .success,
        let role = roleRaw as? String else {
            return nil
        }
        var valueRaw: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(
            element,
            kAXValueAttribute as CFString,
            &valueRaw
        )
        return (role, valueRaw as? String)
    }

    static func confirmsTyped(value: String?, expected: String) -> Bool {
        guard let value else { return false }
        let collapse: (String) -> String = {
            $0.split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
                .lowercased()
        }
        return collapse(value).contains(collapse(expected))
    }

    static func readBack(value: String?, expected: String) -> ReadBack {
        guard value != nil else { return .unobservable }
        return confirmsTyped(value: value, expected: expected) ? .confirmed : .missing
    }

    static func typeUnicode(_ text: String) {
        let source = CGEventSource(stateID: .hidSystemState)
        let units = Array(text.utf16)
        for chunk in stride(from: 0, to: units.count, by: 20) {
            let end = min(chunk + 20, units.count)
            let string = String(decoding: units[chunk..<end], as: UTF16.self)
            let utf16 = Array(string.utf16)
            utf16.withUnsafeBufferPointer { buffer in
                guard let baseAddress = buffer.baseAddress else { return }
                let down = CGEvent(
                    keyboardEventSource: source,
                    virtualKey: 0,
                    keyDown: true
                )
                let up = CGEvent(
                    keyboardEventSource: source,
                    virtualKey: 0,
                    keyDown: false
                )
                down?.keyboardSetUnicodeString(
                    stringLength: buffer.count,
                    unicodeString: baseAddress
                )
                up?.keyboardSetUnicodeString(
                    stringLength: buffer.count,
                    unicodeString: baseAddress
                )
                down?.post(tap: .cghidEventTap)
                up?.post(tap: .cghidEventTap)
            }
            if end < units.count {
                Thread.sleep(forTimeInterval: 0.008)
            }
        }
    }
}
