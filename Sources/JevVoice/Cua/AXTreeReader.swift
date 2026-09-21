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

private func axFrame(position: CFTypeRef?, size: CFTypeRef?) -> CGRect? {
    guard let position,
          let size,
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

private func axElement(_ value: CFTypeRef?) -> AXUIElement? {
    guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
        return nil
    }
    return unsafeDowncast(value, to: AXUIElement.self)
}

private struct AXElementNode: AXNode {
    let element: AXUIElement
    let role: String
    let subrole: String?
    let title: String?
    let axDescription: String?
    let stringValue: String?
    let placeholder: String?
    let frame: CGRect?
    private let storedChildren: [AXUIElement]

    init(element: AXUIElement) {
        self.element = element
        let attributes: [CFString] = [
            kAXRoleAttribute as CFString,
            kAXSubroleAttribute as CFString,
            kAXTitleAttribute as CFString,
            kAXDescriptionAttribute as CFString,
            kAXValueAttribute as CFString,
            "AXPlaceholderValue" as CFString,
            kAXPositionAttribute as CFString,
            kAXSizeAttribute as CFString,
            kAXChildrenAttribute as CFString,
        ]
        var rawValues: CFArray?
        let result = AXUIElementCopyMultipleAttributeValues(
            element,
            attributes as CFArray,
            [],
            &rawValues
        )
        let values = result == .success ? (rawValues as? [Any]) ?? [] : []
        role = values[safe: 0] as? String ?? ""
        subrole = values[safe: 1] as? String
        title = values[safe: 2] as? String
        axDescription = values[safe: 3] as? String
        stringValue = values[safe: 4] as? String
        placeholder = values[safe: 5] as? String
        frame = axFrame(
            position: values[safe: 6] as CFTypeRef?,
            size: values[safe: 7] as CFTypeRef?
        )
        storedChildren = (values[safe: 8] as? [AXUIElement])
            .map { Array($0.prefix(200)) } ?? []
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
        storedChildren.map(AXElementNode.init)
    }
}

private extension Array {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
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
    private struct WalkResult<N: AXNode> {
        let nodes: [(node: N, role: String, label: String, value: String?)]
        let partial: Bool
    }

    static let interactiveRoles: Set<String> = [
        "AXButton", "AXLink", "AXMenuItem", "AXTab", "AXCheckBox",
        "AXRadioButton", "AXPopUpButton", "AXComboBox", "AXRow", "AXCell",
        "AXTextField", "AXTextArea", "AXSearchField", "AXSlider",
        "AXIncrementor", "AXDisclosureTriangle",
    ]

    static let labelRoles: Set<String> = [
        "AXStaticText", "AXHeading", "AXImage", "AXLink", "AXMenuBarItem",
    ]

    static func windowIdentifiers(pid: pid_t) -> [String] {
        let app = AXUIElementCreateApplication(pid)
        guard let value = axAttribute(app, kAXWindowsAttribute as CFString),
              let windows = value as? [AXUIElement] else {
            return []
        }
        return windows.flatMap { window in
            [kAXTitleAttribute as CFString, kAXDocumentAttribute as CFString, "AXURL" as CFString]
                .compactMap { attribute in
                    guard let value = axAttribute(window, attribute) else { return nil }
                    if let string = value as? String { return string }
                    if let url = value as? URL { return url.absoluteString }
                    return String(describing: value)
                }
        }
    }

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
        let focused = axElement(axAttribute(app, kAXFocusedWindowAttribute as CFString))
        let main = axElement(axAttribute(app, kAXMainWindowAttribute as CFString))
        return focused ?? main
    }

    static func walk<N: AXNode>(
        _ root: N,
        maxElements: Int = 600,
        deadline: Date
    ) -> [(node: N, role: String, label: String, value: String?)]? {
        walkResult(root, maxElements: maxElements, deadline: deadline)?.nodes
    }

    private static func walkResult<N: AXNode>(
        _ root: N,
        maxElements: Int = 600,
        deadline: Date,
        requireInteractive: Bool = true
    ) -> WalkResult<N>? {
        var queue = [root]
        var index = 0
        var result: [(node: N, role: String, label: String, value: String?)] = []
        var interactiveCount = 0
        var seen = Set<NodeKey>()

        while index < queue.count {
            guard Date() < deadline else {
                guard requireInteractive || interactiveCount >= 3 else {
                    return nil
                }
                return WalkResult(nodes: result, partial: true)
            }
            let node = queue[index]
            index += 1
            let role = node.role
            let frame = node.frame
            if frame?.width == 0 || frame?.height == 0 {
                queue.append(contentsOf: node.children)
                continue
            }
            let isTextInput = ["AXTextField", "AXTextArea", "AXSearchField"].contains(role)
            let preferredLabel = [node.title, node.axDescription, node.placeholder]
                .compactMap { $0 }
                .first
            let label: String
            if let preferredLabel {
                label = preferredLabel
            } else if (labelRoles.contains(role) || isTextInput),
                      let stringValue = node.stringValue,
                      !stringValue.isEmpty {
                label = stringValue
            } else {
                label = switch role {
                case "AXTextField": "text field"
                case "AXTextArea": "text area"
                case "AXSearchField": "search field"
                default: ""
                }
            }
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
                guard !requireInteractive || interactiveCount >= 3 else { return nil }
                return WalkResult(nodes: result, partial: false)
            }
        }
        return !requireInteractive || interactiveCount >= 3
            ? WalkResult(nodes: result, partial: false)
            : nil
    }

    static func snapshot(
        pid: Int,
        windowFrame: CGRect?,
        full: Bool = false
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
              let initial = walkResult(
                  AXElementNode(element: root),
                  deadline: Date().addingTimeInterval(full ? 4.0 : 1.5),
                  requireInteractive: !full
              ) else {
            return nil
        }
        if full {
            return snapshot(nodes: initial.nodes, partial: initial.partial)
        }
        let nodes = initial.nodes
        if shouldRewalk(
            interactiveCount: nodes.filter({ interactiveRoles.contains($0.role) }).count,
            frame: windowFrame
        ) {
            let textInputRoles = Set(["AXTextArea", "AXTextField", "AXComboBox"])
            let poke: String
            if let textInput = nodes.first(where: { textInputRoles.contains($0.role) }) {
                let result = AXUIElementSetAttributeValue(
                    textInput.node.element,
                    kAXFocusedAttribute as CFString,
                    kCFBooleanTrue
                )
                poke = result == .success ? "focus" : "scroll"
                if result != .success {
                    postZeroDeltaScroll(at: windowFrame?.center ?? .zero)
                }
            } else {
                poke = "scroll"
                postZeroDeltaScroll(at: windowFrame?.center ?? .zero)
            }
            Thread.sleep(forTimeInterval: 0.25)
            let rewalked = walkResult(
                AXElementNode(element: root),
                deadline: Date().addingTimeInterval(1.2)
            ) ?? WalkResult(nodes: nodes, partial: false)
            let beforeCount = nodes.filter {
                interactiveRoles.contains($0.role)
            }.count
            let rewalkedNodes = rewalked.nodes
            let afterCount = rewalkedNodes.filter {
                interactiveRoles.contains($0.role)
            }.count
            Log.agent.info(
                "axtree rewalk before=\(beforeCount, privacy: .public) after=\(afterCount, privacy: .public) poke=\(poke, privacy: .public)"
            )
            return snapshot(
                nodes: rewalkedNodes,
                partial: initial.partial || rewalked.partial
            )
        }
        return snapshot(nodes: nodes, partial: initial.partial)
    }

    static func wake(pid: Int, windowFrame: CGRect?) -> (before: Int, after: Int, method: String)? {
        guard let root = window(pid: pid_t(pid), frame: windowFrame) else { return nil }
        let beforeNodes = walk(
            AXElementNode(element: root),
            deadline: Date().addingTimeInterval(1.5)
        ) ?? []
        let before = beforeNodes.filter { interactiveRoles.contains($0.role) }.count
        let background = beforeNodes
            .filter {
                ["AXGroup", "AXWebArea", "AXScrollArea"].contains($0.role)
                    && $0.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && ($0.node.frame?.width ?? 0) > 0
                    && ($0.node.frame?.height ?? 0) > 0
            }
            .max {
                ($0.node.frame?.width ?? 0) * ($0.node.frame?.height ?? 0)
                    < ($1.node.frame?.width ?? 0) * ($1.node.frame?.height ?? 0)
            }
        var method = "mouse"
        if let background,
           AXUIElementPerformAction(background.node.element, kAXPressAction as CFString) == .success {
            method = "axpress"
        }
        if let windowFrame {
            postMouseMoved(at: windowFrame.center)
        }
        Thread.sleep(forTimeInterval: 0.3)
        let afterNodes = walk(
            AXElementNode(element: root),
            deadline: Date().addingTimeInterval(4.0)
        ) ?? beforeNodes
        let after = afterNodes.filter { interactiveRoles.contains($0.role) }.count
        Log.agent.info(
            "axtree wake before=\(before, privacy: .public) after=\(after, privacy: .public) method=\(method, privacy: .public)"
        )
        return (before, after, method)
    }

    static func shouldRewalk(interactiveCount: Int, frame: CGRect?) -> Bool {
        guard let frame else { return false }
        let threshold = max(10, Int(frame.width * frame.height / 150_000))
        return interactiveCount < threshold && frame.width > 400 && frame.height > 300
    }

    private static func postZeroDeltaScroll(at point: CGPoint) {
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 3,
            wheel1: 0,
            wheel2: 0,
            wheel3: 0
        ) else { return }
        event.location = point
        event.post(tap: .cghidEventTap)
    }

    static func snapshot<N: AXNode>(
        _ root: N,
        deadline: Date = Date().addingTimeInterval(0.3)
    ) -> (snapshot: CuaSnapshot, entries: [String: AXEntry])? {
        guard let nodes = walk(root, deadline: deadline) else { return nil }
        return snapshot(nodes: nodes)
    }

    private static func snapshot<N: AXNode>(
        nodes: [(node: N, role: String, label: String, value: String?)],
        partial: Bool = false
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
                image: nil,
                partial: partial
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

    private static func postMouseMoved(at point: CGPoint) {
        guard let event = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: point,
            mouseButton: .left
        ) else { return }
        event.post(tap: .cghidEventTap)
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

enum CGEventClicker {
    static func click(at point: CGPoint) {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let moved = CGEvent(
                  mouseEventSource: source,
                  mouseType: .mouseMoved,
                  mouseCursorPosition: point,
                  mouseButton: .left
              ),
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
        moved.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.03)
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }
}
