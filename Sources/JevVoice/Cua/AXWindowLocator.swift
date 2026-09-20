import ApplicationServices
import CoreGraphics

enum AXWindowLocator {
    /// Frame (screen coords, top-left origin like Cua bounds) of the app's focused window, else main window.
    static func focusedWindowFrame(pid: pid_t) -> CGRect? {
        let app = AXUIElementCreateApplication(pid)
        let focused = element(app, kAXFocusedWindowAttribute as CFString)
            ?? element(app, kAXMainWindowAttribute as CFString)
        guard let focused else { return nil }
        return frame(of: focused)
    }

    private static func element(_ parent: AXUIElement, _ name: CFString) -> AXUIElement? {
        guard let value = attribute(parent, name),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    private static func frame(of window: AXUIElement) -> CGRect? {
        guard let position = attribute(window, kAXPositionAttribute as CFString),
              let size = attribute(window, kAXSizeAttribute as CFString),
              CFGetTypeID(position) == AXValueGetTypeID(),
              CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        let positionValue = unsafeDowncast(position, to: AXValue.self)
        let sizeValue = unsafeDowncast(size, to: AXValue.self)
        var point = CGPoint.zero
        var dimensions = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &point),
              AXValueGetValue(sizeValue, .cgSize, &dimensions) else { return nil }
        return CGRect(origin: point, size: dimensions)
    }

    private static func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else {
            return nil
        }
        return value
    }
}
