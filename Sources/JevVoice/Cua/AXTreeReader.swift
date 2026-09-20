import ApplicationServices
import CoreGraphics
import Foundation

protocol AXNode {
    var role: String { get }
    var subrole: String? { get }
    var title: String? { get }
    var axDescription: String? { get }
    var stringValue: String? { get }
    var placeholder: String? { get }
    var frame: CGRect? { get }
    var actionNames: [String] { get }
    var children: [Self] { get }
}

private func axAttribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name, &value) == .success else {
        return nil
    }
    return value
}

private func axString(_ element: AXUIElement, _ name: CFString) -> String? {
    axAttribute(element, name) as? String
}

private func axFrame(_ element: AXUIElement) -> CGRect? {
    guard let position = axAttribute(element, kAXPositionAttribute as CFString),
          let size = axAttribute(element, kAXSizeAttribute as CFString),
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

private struct AXElementNode: AXNode {
    let element: AXUIElement

    var role: String {
        axString(element, kAXRoleAttribute as CFString) ?? ""
    }

    var subrole: String? {
        axString(element, kAXSubroleAttribute as CFString)
    }

    var title: String? {
        axString(element, kAXTitleAttribute as CFString)
    }

    var axDescription: String? {
        axString(element, kAXDescriptionAttribute as CFString)
    }

    var stringValue: String? {
        axString(element, kAXValueAttribute as CFString)
    }

    var placeholder: String? {
        axString(element, "AXPlaceholderValue" as CFString)
    }

    var frame: CGRect? {
        axFrame(element)
    }

    var actionNames: [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success,
              let names else {
            return []
        }
        return (names as? [String]) ?? []
    }

    var children: [AXElementNode] {
        guard let value = axAttribute(element, kAXChildrenAttribute as CFString),
              let children = value as? [AXUIElement] else {
            return []
        }
        return Array(children.prefix(200)).map(AXElementNode.init)
    }
}

struct AXEntry {
    let element: AXUIElement?
    let frame: CGRect?
    let role: String
    let label: String
    let value: String?
    let actions: [String]
}

enum AXTreeError: Error, LocalizedError {
    case noPress
    case actionFailed(String)
    case focusFailed(String)

    var errorDescription: String? {
        switch self {
        case .noPress:
            return "Accessibility element does not support AXPress"
        case .actionFailed(let message):
            return message
        case .focusFailed(let message):
            return message
        }
    }
}

enum AXTreeReader {
    static let interactiveRoles: Set<String> = [
        "AXButton", "AXLink", "AXMenuItem", "AXTab", "AXCheckBox",
        "AXRadioButton", "AXPopUpButton", "AXComboBox", "AXRow", "AXCell",
        "AXTextField", "AXTextArea", "AXSearchField", "AXSlider",
        "AXIncrementor", "AXDisclosureTriangle",
    ]

    static let labelRoles: Set<String> = [
        "AXStaticText", "AXHeading", "AXImage", "AXLink", "AXMenuBarItem",
    ]

    private static let valueRoles: Set<String> = [
        "AXTextField", "AXTextArea", "AXSearchField", "AXCheckBox",
        "AXPopUpButton", "AXComboBox",
    ]

    static func window(pid: pid_t, frame: CGRect?) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        guard let value = axAttribute(app, kAXWindowsAttribute as CFString),
              let windows = value as? [AXUIElement] else {
            return nil
        }
        if let frame {
            return windows.first { candidate in
                guard let candidateFrame = AXElementNode(element: candidate).frame else { return false }
                return abs(candidateFrame.origin.x - frame.origin.x) <= 4
                    && abs(candidateFrame.origin.y - frame.origin.y) <= 4
                    && abs(candidateFrame.size.width - frame.size.width) <= 4
                    && abs(candidateFrame.size.height - frame.size.height) <= 4
            }
        }
        let focused = axAttribute(app, kAXFocusedWindowAttribute as CFString)
            .map { unsafeDowncast($0, to: AXUIElement.self) }
        let main = axAttribute(app, kAXMainWindowAttribute as CFString)
            .map { unsafeDowncast($0, to: AXUIElement.self) }
        return focused ?? main
    }

    static func walk<N: AXNode>(
        _ root: N,
        maxElements: Int = 600,
        deadline: Date
    ) -> [(node: N, role: String, label: String, value: String?)]? {
        var queue = [root]
        var index = 0
        var result: [(node: N, role: String, label: String, value: String?)] = []
        var interactiveCount = 0
        var seen = Set<NodeKey>()

        while index < queue.count {
            guard Date() < deadline else { return nil }
            let node = queue[index]
            index += 1
            let role = node.role
            let frame = node.frame
            if frame?.width == 0 || frame?.height == 0 {
                queue.append(contentsOf: node.children)
                continue
            }
            let isTextInput = ["AXTextField", "AXTextArea", "AXSearchField"].contains(role)
            let label = node.title
                ?? node.axDescription
                ?? node.placeholder
                ?? ((labelRoles.contains(role) || isTextInput) ? node.stringValue : nil)
                ?? ""
            let isEmittable = interactiveRoles.contains(role) || labelRoles.contains(role)
            if isEmittable && !label.isEmpty {
                let key = NodeKey(role: role, label: label, frame: frame)
                if seen.insert(key).inserted {
                    let value = valueRoles.contains(role) ? node.stringValue : nil
                    result.append((node: node, role: role, label: label, value: value))
                    if interactiveRoles.contains(role) {
                        interactiveCount += 1
                    }
                }
            }
            queue.append(contentsOf: node.children)
            if result.count >= maxElements {
                guard interactiveCount >= 3 else { return nil }
                return result
            }
        }
        return interactiveCount >= 3 ? result : nil
    }

    @MainActor
    static func snapshot(
        pid: Int,
        windowFrame: CGRect?
    ) -> (snapshot: CuaSnapshot, entries: [String: AXEntry])? {
        let app = AXUIElementCreateApplication(pid_t(pid))
        _ = AXUIElementSetAttributeValue(
            app,
            "AXManualAccessibility" as CFString,
            kCFBooleanTrue
        )
        _ = AXUIElementSetAttributeValue(
            app,
            "AXEnhancedUserInterface" as CFString,
            kCFBooleanTrue
        )
        guard let root = window(pid: pid_t(pid), frame: windowFrame),
              let nodes = walk(
                  AXElementNode(element: root),
                  deadline: Date().addingTimeInterval(0.3)
              ) else {
            return nil
        }
        return snapshot(nodes: nodes)
    }

    static func snapshot<N: AXNode>(
        _ root: N,
        deadline: Date = Date().addingTimeInterval(0.3)
    ) -> (snapshot: CuaSnapshot, entries: [String: AXEntry])? {
        guard let nodes = walk(root, deadline: deadline) else { return nil }
        return snapshot(nodes: nodes)
    }

    private static func snapshot<N: AXNode>(
        nodes: [(node: N, role: String, label: String, value: String?)]
    ) -> (snapshot: CuaSnapshot, entries: [String: AXEntry]) {
        var entries: [String: AXEntry] = [:]
        var elements: [CuaElement] = []
        var lines: [String] = []
        for (index, item) in nodes.enumerated() {
            let token = "ax:\(index + 1)"
            let entry = AXEntry(
                element: (item.node as? AXElementNode)?.element,
                frame: item.node.frame,
                role: item.role,
                label: item.label,
                value: item.value,
                actions: item.node.actionNames
            )
            entries[token] = entry
            elements.append(CuaElement(
                token: token,
                role: item.role,
                label: item.label,
                value: item.value
            ))
            let value = item.value.map { " value=\($0)" } ?? ""
            lines.append("[\(token)] \(item.role) \(item.label)\(value)")
        }
        return (
            CuaSnapshot(
                snapshotId: UUID().uuidString,
                treeMarkdown: lines.joined(separator: "\n"),
                elements: elements,
                image: nil
            ),
            entries
        )
    }

    static func press(_ entry: AXEntry) throws {
        guard let element = entry.element, entry.actions.contains("AXPress") else {
            throw AXTreeError.noPress
        }
        let result = AXUIElementPerformAction(element, kAXPressAction as CFString)
        guard result == .success else {
            throw AXTreeError.actionFailed("AXPress failed: \(result.rawValue)")
        }
    }

    static func focus(_ entry: AXEntry) throws {
        guard let element = entry.element else {
            throw AXTreeError.focusFailed("Accessibility element is unavailable")
        }
        let result = AXUIElementSetAttributeValue(
            element,
            kAXFocusedAttribute as CFString,
            kCFBooleanTrue
        )
        guard result == .success else {
            throw AXTreeError.focusFailed("AX focus failed: \(result.rawValue)")
        }
    }

    private struct NodeKey: Hashable {
        let role: String
        let label: String
        let x: Int
        let y: Int
        let width: Int
        let height: Int

        init(role: String, label: String, frame: CGRect?) {
            self.role = role
            self.label = label
            x = Int((frame?.origin.x ?? 0).rounded())
            y = Int((frame?.origin.y ?? 0).rounded())
            width = Int((frame?.size.width ?? 0).rounded())
            height = Int((frame?.size.height ?? 0).rounded())
        }
    }
}

enum CGEventClicker {
    static func click(at point: CGPoint) {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(
                  mouseEventSource: source,
                  mouseType: .leftMouseDown,
                  mouseCursorPosition: point,
                  mouseButton: .left
              ),
              let up = CGEvent(
                  mouseEventSource: source,
                  mouseType: .leftMouseUp,
                  mouseCursorPosition: point,
                  mouseButton: .left
              ) else {
            return
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
