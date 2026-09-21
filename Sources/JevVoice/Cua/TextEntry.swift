import ApplicationServices
import Foundation

enum TextEntry {
    private static let acceptedRoles: Set<String> = [
        "AXTextField",
        "AXTextArea",
        "AXSearchField",
        "AXComboBox",
    ]

    private static let preferredTerms = [
        "prompt",
        "message",
        "ask",
        "type",
        "search",
    ]

    static func focusedTextInput(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        guard let focused = attribute(app, kAXFocusedUIElementAttribute as CFString),
              let element = axElement(focused),
              isTextInput(element) else {
            return nil
        }
        return element
    }

    static func focusTextElementIfNeeded(pid: pid_t) -> Bool {
        if focusedTextInput(pid: pid) != nil {
            return true
        }
        let app = AXUIElementCreateApplication(pid)
        guard let windowValue = attribute(app, kAXFocusedWindowAttribute as CFString)
                ?? attribute(app, kAXMainWindowAttribute as CFString),
              let window = axElement(windowValue) else {
            return false
        }
        let candidates = textInputs(in: window)
        guard let candidate = candidates.max(by: isBetterCandidate) else {
            return false
        }
        Log.agent.info("stage=focus role=\(role(of: candidate.element), privacy: .public)")
        let pressed = AXUIElementPerformAction(candidate.element, kAXPressAction as CFString) == .success
        let focused = AXUIElementSetAttributeValue(
            candidate.element,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        ) == .success
        return pressed || focused
    }

    static func readBack(pid: pid_t, text: String) -> KeyboardFocus.ReadBack {
        guard let element = focusedTextInput(pid: pid),
              let value = attribute(element, kAXValueAttribute as CFString) as? String else {
            return .unobservable
        }
        return KeyboardFocus.readBack(value: value, expected: text)
    }

    static func verifyTyped(pid: pid_t, text: String) -> Bool {
        readBack(pid: pid, text: text) == .confirmed
    }

    private struct Candidate {
        let element: AXUIElement
        let area: CGFloat
        let preference: Int
    }

    private static func textInputs(in root: AXUIElement) -> [Candidate] {
        var result: [Candidate] = []
        var queue = [(root, 0)]
        while let (element, depth) = queue.popLast() {
            guard depth <= 8 else { continue }
            if isTextInput(element), let frame = frame(of: element), frame.width > 0, frame.height > 0,
               (attribute(element, kAXHiddenAttribute as CFString) as? Bool) != true {
                let metadata = [
                    attribute(element, "AXPlaceholderValue" as CFString) as? String,
                    attribute(element, kAXTitleAttribute as CFString) as? String,
                    attribute(element, kAXDescriptionAttribute as CFString) as? String,
                ]
                let preference = preferredTerms.enumerated().compactMap { index, term in
                    metadata.contains { $0?.localizedCaseInsensitiveContains(term) == true }
                        ? preferredTerms.count - index
                        : nil
                }.max() ?? 0
                result.append(Candidate(
                    element: element,
                    area: frame.width * frame.height,
                    preference: preference
                ))
            }
            if let children = attribute(element, kAXChildrenAttribute as CFString) as? [AXUIElement] {
                queue.append(contentsOf: children.map { ($0, depth + 1) })
            }
        }
        return result
    }

    private static func isBetterCandidate(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        if lhs.preference != rhs.preference {
            return lhs.preference > rhs.preference
        }
        return lhs.area > rhs.area
    }

    private static func isTextInput(_ element: AXUIElement) -> Bool {
        let role = role(of: element)
        if acceptedRoles.contains(role) {
            return true
        }
        if (attribute(element, kAXRoleDescriptionAttribute as CFString) as? String)?
            .localizedCaseInsensitiveContains("text") == true {
            return true
        }
        if (attribute(element, "AXEditable" as CFString) as? Bool) == true {
            return true
        }
        return false
    }

    private static func role(of element: AXUIElement) -> String {
        attribute(element, kAXRoleAttribute as CFString) as? String ?? ""
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

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let position = attribute(element, kAXPositionAttribute as CFString),
              let size = attribute(element, kAXSizeAttribute as CFString),
              CFGetTypeID(position) == AXValueGetTypeID(),
              CFGetTypeID(size) == AXValueGetTypeID() else {
            return nil
        }
        let positionValue = unsafeDowncast(position, to: AXValue.self)
        let sizeValue = unsafeDowncast(size, to: AXValue.self)
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &point),
              AXValueGetValue(sizeValue, .cgSize, &dimensions) else {
            return nil
        }
        return CGRect(origin: point, size: dimensions)
    }
}
