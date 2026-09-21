import ApplicationServices
import CoreFoundation
import Foundation
import JevVoiceCore

enum AXMenuBar {
    static func pressMenuItem(
        pid: pid_t,
        key: String,
        modifiers: [String],
        goal: String? = nil
    ) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        guard let menuBarValue = attribute(app, kAXMenuBarAttribute as CFString),
              let menuBar = axElement(menuBarValue) else {
            return false
        }
        var queue: [(AXUIElement, Int)] = [(menuBar, 0)]
        while let (element, depth) = queue.popLast() {
            guard depth <= 3 else { continue }
            if matches(element, key: key, modifiers: modifiers) {
                let title = attribute(element, kAXTitleAttribute as CFString) as? String ?? key
                if let goal,
                   GoalWords.words(title).isDisjoint(with: GoalWords.words(goal)) {
                    Log.agent.info(
                        "stage=menu item=\(title, privacy: .public) skipped=goal-mismatch"
                    )
                    return false
                }
                guard AXUIElementPerformAction(element, kAXPressAction as CFString) == .success else {
                    continue
                }
                Log.agent.info("stage=menu item=\(title, privacy: .public)")
                return true
            }
            if let children = attribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] {
                queue.append(contentsOf: children.map { ($0, depth + 1) })
            }
        }
        return false
    }

    static func modifiersMatch(mask: UInt32, modifiers: [String]) -> Bool {
        let normalized = Set(modifiers.map { $0.lowercased() })
        let wantsCommand = normalized.contains("command")
        var expected: UInt32 = wantsCommand ? 0 : 8
        if normalized.contains("shift") { expected |= 1 }
        if normalized.contains("option") { expected |= 2 }
        if normalized.contains("control") { expected |= 4 }
        return mask == expected
    }

    private static func matches(
        _ element: AXUIElement,
        key: String,
        modifiers: [String]
    ) -> Bool {
        guard let commandKey = attribute(element, kAXMenuItemCmdCharAttribute as CFString) as? String,
              commandKey.caseInsensitiveCompare(key) == .orderedSame,
              let rawMask = attribute(element, kAXMenuItemCmdModifiersAttribute as CFString) else {
            return false
        }
        var maskValue: Int32 = 0
        guard CFGetTypeID(rawMask) == CFNumberGetTypeID(),
              CFNumberGetValue(
                  unsafeDowncast(rawMask, to: CFNumber.self),
                  CFNumberType.sInt32Type,
                  &maskValue
              ) else {
            return false
        }
        return modifiersMatch(mask: UInt32(maskValue), modifiers: modifiers)
    }

    private static func axElement(_ value: CFTypeRef) -> AXUIElement? {
        guard CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else {
            return nil
        }
        return value
    }
}
