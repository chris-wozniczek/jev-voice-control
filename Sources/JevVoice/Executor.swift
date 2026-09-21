import AppKit
import CoreGraphics
import JevVoiceCore

enum ExecutorError: Error, LocalizedError {
    case appNotFound(String)
    case missingSlot(String)
    case controlFailed(String)

    var errorDescription: String? {
        switch self {
        case .appNotFound(let name): return "Could not find app: \(name)"
        case .missingSlot(let what): return "Missing \(what)"
        case .controlFailed(let what): return what
        }
    }
}

enum Executor {
    static let noFocusedFieldMessage = "Nothing to type into — click where the text should go first"

    @MainActor
    static func execute(
        _ decision: Decision,
        frontmostApp: String? = nil
    ) async throws -> String {
        switch decision.action {
        case .openApp:
            guard let name = decision.targetApp else { throw ExecutorError.missingSlot("target app") }
            return try await openApp(named: name)
        case .closeApp:
            guard let name = decision.targetApp else { throw ExecutorError.missingSlot("target app") }
            return closeApp(named: name)
        case .switchApp:
            guard let name = decision.targetApp else { throw ExecutorError.missingSlot("target app") }
            return try await switchApp(named: name)
        case .minimizeApp:
            guard let name = decision.targetApp else { throw ExecutorError.missingSlot("target app") }
            return try minimizeApp(named: name)
        case .maximizeApp:
            guard let name = decision.targetApp else { throw ExecutorError.missingSlot("target app") }
            return try await maximizeApp(named: name)
        case .fullscreenApp:
            guard let name = decision.targetApp else { throw ExecutorError.missingSlot("target app") }
            return try await fullscreenApp(named: name)
        case .restoreApp:
            guard let name = decision.targetApp else { throw ExecutorError.missingSlot("target app") }
            return try restoreApp(named: name)
        case .hideApp:
            guard let name = decision.targetApp else { throw ExecutorError.missingSlot("target app") }
            return try hideApp(named: name)
        case .openURL:
            guard let urlString = decision.url, let url = URL(string: urlString) else {
                throw ExecutorError.missingSlot("url")
            }
            return try await open(url, browser: decision.targetApp)
        case .webSearch:
            guard let query = decision.query else { throw ExecutorError.missingSlot("query") }
            var components = URLComponents(string: "https://www.google.com/search")!
            components.queryItems = [URLQueryItem(name: "q", value: query)]
            guard let url = components.url else { throw ExecutorError.missingSlot("query") }
            return try await open(url, browser: decision.targetApp)
        case .dictate:
            guard let text = decision.text else { throw ExecutorError.missingSlot("text") }
            return await dictate(text, frontmostApp: frontmostApp)
        case .uiTask:
            throw ExecutorError.controlFailed("uiTask is handled by the agent")
        case .system:
            return try runSystem(decision.systemAction ?? .none, percent: decision.percent)
        case .none:
            return "No action"
        }
    }

    @MainActor
    private static func openApp(named name: String) async throws -> String {
        guard let url = InstalledApps.appURL(named: name) else {
            throw ExecutorError.appNotFound(name)
        }
        try await NSWorkspace.shared.openApplication(at: url, configuration: .init())
        try await waitForApplication(url: url, timeout: 3.0, requireFrontmost: false)
        return "Opened \(name)"
    }

    @MainActor
    private static func waitForApplication(
        url: URL, timeout: TimeInterval, requireFrontmost: Bool
    ) async throws {
        let attempts = Int(timeout / 0.1)
        for attempt in 0...attempts {
            let isFrontmost = NSWorkspace.shared.frontmostApplication?.bundleURL == url
            let isRunning = NSWorkspace.shared.runningApplications.contains {
                $0.bundleURL == url
            }
            if isFrontmost || (!requireFrontmost && isRunning) { return }
            if attempt < attempts {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }

    private static func runningApp(named name: String) -> NSRunningApplication? {
        let apps = NSWorkspace.shared.runningApplications
        return apps.first { $0.localizedName?.caseInsensitiveCompare(name) == .orderedSame }
            ?? apps.first { $0.localizedName?.lowercased().contains(name.lowercased()) ?? false }
    }

    private static func closeApp(named name: String) -> String {
        guard let app = runningApp(named: name) else { return "\(name) is not running" }
        app.terminate()
        return "Quit \(app.localizedName ?? name)"
    }

    @MainActor
    private static func switchApp(named name: String) async throws -> String {
        if let app = runningApp(named: name) {
            let shown = app.localizedName ?? name
            app.unhide()
            guard app.activate(options: [.activateAllWindows]) else {
                throw ExecutorError.controlFailed("Could not switch to \(shown)")
            }
            if let url = app.bundleURL {
                try await waitForApplication(url: url, timeout: 1.5, requireFrontmost: true)
            }
            return "Switched to \(shown)"
        }
        return try await openApp(named: name)
    }

    private static func minimizeApp(named name: String) throws -> String {
        guard let app = runningApp(named: name) else { return "\(name) is not running" }
        let windows = try WindowControl.windows(of: app)
        var minimized = 0
        for window in windows {
            guard AXUIElementSetAttributeValue(
                window, kAXMinimizedAttribute as CFString, kCFBooleanTrue
            ) == .success else { continue }
            if WindowControl.isMinimized(window) == true { minimized += 1 }
        }
        guard minimized > 0 else {
            throw ExecutorError.controlFailed("Could not minimize \(app.localizedName ?? name)")
        }
        return "Minimized \(app.localizedName ?? name)"
    }

    @MainActor
    private static func maximizeApp(named name: String) async throws -> String {
        guard let app = runningApp(named: name) else { return "\(name) is not running" }
        try WindowControl.requireAccessibility()
        app.unhide()
        for window in try WindowControl.windows(of: app) {
            _ = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        guard app.activate(options: [.activateAllWindows]) else {
            throw ExecutorError.controlFailed("Could not activate \(name)")
        }
        if let url = app.bundleURL {
            try await waitForApplication(url: url, timeout: 1.0, requireFrontmost: true)
        }
        guard let window = try WindowControl.focusedWindow(of: app),
              let currentFrame = WindowControl.frame(of: window) else {
            throw ExecutorError.controlFailed("Could not find a window for \(name)")
        }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? currentFrame.height
        let currentCocoaFrame = CGRect(
            x: currentFrame.minX,
            y: primaryHeight - currentFrame.maxY,
            width: currentFrame.width,
            height: currentFrame.height
        )
        let screen = NSScreen.screens.first {
            $0.visibleFrame.intersects(currentCocoaFrame)
        } ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let target = CGRect(
            x: visible.minX,
            y: primaryHeight - visible.maxY,
            width: visible.width,
            height: visible.height
        )
        WindowControl.set(frame: target, of: window)
        if let frame = WindowControl.frame(of: window), WindowControl.isNear(frame, target) {
            return "Maximized \(name)"
        }
        if let button = WindowControl.element(window, kAXZoomButtonAttribute as CFString) {
            _ = AXUIElementPerformAction(button, kAXPressAction as CFString)
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        if let frame = WindowControl.frame(of: window), WindowControl.isNear(frame, target) {
            return "Maximized \(name)"
        }
        throw ExecutorError.controlFailed("Could not maximize \(name)")
    }

    @MainActor
    private static func fullscreenApp(named name: String) async throws -> String {
        guard let app = runningApp(named: name) else { return "\(name) is not running" }
        try WindowControl.requireAccessibility()
        guard let window = try WindowControl.focusedWindow(of: app) else {
            throw ExecutorError.controlFailed("Could not find a window for \(name)")
        }
        if WindowControl.booleanAttribute(window, "AXFullScreen") == true {
            return "\(name) is already full screen"
        }
        guard AXUIElementSetAttributeValue(
            window, "AXFullScreen" as CFString, kCFBooleanTrue
        ) == .success else {
            throw ExecutorError.controlFailed("Could not enter full screen for \(name)")
        }
        for _ in 0..<15 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if WindowControl.booleanAttribute(window, "AXFullScreen") == true {
                return "Full screen \(name)"
            }
        }
        throw ExecutorError.controlFailed("Could not enter full screen for \(name)")
    }

    private static func restoreApp(named name: String) throws -> String {
        guard let app = runningApp(named: name) else { return "\(name) is not running" }
        try WindowControl.requireAccessibility()
        app.unhide()
        let windows = try WindowControl.windows(of: app)
        for window in windows {
            _ = AXUIElementSetAttributeValue(window, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        _ = app.activate(options: [.activateAllWindows])
        guard windows.contains(where: { WindowControl.isMinimized($0) == false }) else {
            throw ExecutorError.controlFailed("Could not restore \(name)")
        }
        return "Restored \(name)"
    }

    private static func hideApp(named name: String) throws -> String {
        guard let app = runningApp(named: name) else { return "\(name) is not running" }
        guard app.hide() else { throw ExecutorError.controlFailed("Could not hide \(app.localizedName ?? name)") }
        return "Hid \(app.localizedName ?? name)"
    }

    @MainActor
    private static func open(_ url: URL, browser: String?) async throws -> String {
        if let browser, let appURL = InstalledApps.appURL(named: browser) {
            try await NSWorkspace.shared.open(
                [url], withApplicationAt: appURL, configuration: .init()
            )
            return "Opened \(url.host ?? url.absoluteString) in \(browser)"
        }
        NSWorkspace.shared.open(url)
        return "Opened \(url.host ?? url.absoluteString)"
    }

    private static func dictate(_ text: String, frontmostApp: String?) async -> String {
        let ownBundleID = Bundle.main.bundleIdentifier
        let application: NSRunningApplication?
        if let frontmostApp {
            application = NSWorkspace.shared.runningApplications.first {
                $0.localizedName?.caseInsensitiveCompare(frontmostApp) == .orderedSame
            }
        } else {
            application = NSWorkspace.shared.frontmostApplication
        }
        if frontmostApp != nil, application == nil {
            return noFocusedFieldMessage
        }
        guard let application,
              application.bundleIdentifier != ownBundleID,
              await KeyboardFocus.bringToFront(pid: application.processIdentifier) else {
            return noFocusedFieldMessage
        }
        let pid = application.processIdentifier
        if TextEntry.focusedTextInput(pid: pid) == nil,
           !TextEntry.focusTextElementIfNeeded(pid: pid),
           TextEntry.focusedTextInput(pid: pid) == nil {
            return noFocusedFieldMessage
        }
        let pasteboard = NSPasteboard.general
        let saved: [NSPasteboardItem] = (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let ourChangeCount = pasteboard.changeCount

        let source = CGEventSource(stateID: .hidSystemState)
        let vDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        let vUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        vDown?.flags = .maskCommand
        vUp?.flags = .maskCommand
        vDown?.post(tap: .cghidEventTap)
        vUp?.post(tap: .cghidEventTap)

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            DispatchQueue.main.async {
                guard pasteboard.changeCount == ourChangeCount else { return }
                pasteboard.clearContents()
                if !saved.isEmpty { pasteboard.writeObjects(saved) }
            }
        }
        try? await Task.sleep(for: .milliseconds(150))
        switch TextEntry.readBack(pid: pid, text: text) {
        case .confirmed:
            return "Typed \"\(text)\""
        case .unobservable:
            Log.agent.info("type readback=unobservable (unverified)")
            return "Typed \"\(text)\""
        case .missing:
            Log.agent.info("type readback=miss")
        }
        _ = try? await CuaDriver.shared.type(pid: Int(pid), text: text)
        try? await Task.sleep(for: .milliseconds(150))
        switch TextEntry.readBack(pid: pid, text: text) {
        case .confirmed:
            return "Typed \"\(text)\""
        case .unobservable:
            Log.agent.info("type readback=unobservable (unverified)")
            return "Typed \"\(text)\""
        case .missing:
            let name = application.localizedName ?? frontmostApp ?? "the app"
            return "Couldn't type into \(name) — the text didn't appear"
        }
    }

    private static func runSystem(_ action: SystemAction, percent: Int?) throws -> String {
        switch action {
        case .volumeSet:
            let level = percent ?? 50
            try osascript("set volume output volume \(level)")
            return "Volume \(level)%"
        case .mute:
            try osascript("set volume with output muted")
            return "Muted"
        case .unmute:
            try osascript("set volume without output muted")
            return "Unmuted"
        case .volumeUp:
            try osascript("set volume output volume (output volume of (get volume settings) + 10)")
            return "Volume up"
        case .volumeDown:
            try osascript("set volume output volume (output volume of (get volume settings) - 10)")
            return "Volume down"
        case .brightnessUp:
            try osascript(#"tell application "System Events" to key code 144"#)
            return "Brightness up"
        case .brightnessDown:
            try osascript(#"tell application "System Events" to key code 145"#)
            return "Brightness down"
        case .showDesktop:
            try osascript(#"tell application "System Events" to key code 103"#)
            return "Show desktop"
        case .lockScreen:
            try process("/usr/bin/pmset", ["displaysleepnow"])
            return "Locked"
        case .sleep:
            try process("/usr/bin/pmset", ["sleepnow"])
            return "Sleeping"
        case .screenshot:
            let stamp = ISO8601DateFormatter().string(from: Date())
                .replacingOccurrences(of: ":", with: "-")
            let path = NSHomeDirectory() + "/Desktop/jev-voice-\(stamp).png"
            try process("/usr/sbin/screencapture", ["-x", path])
            return "Screenshot saved to Desktop"
        case .none:
            return "No system action"
        }
    }

    @discardableResult
    private static func osascript(_ source: String) throws -> String {
        try process("/usr/bin/osascript", ["-e", source])
    }

    @discardableResult
    private static func process(_ launchPath: String, _ arguments: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            throw NSError(
                domain: "JevVoice.Executor", code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: output.isEmpty ? "\(launchPath) failed" : output]
            )
        }
        return output
    }
}

private enum WindowControl {
    static func requireAccessibility() throws {
        guard AXIsProcessTrusted() else {
            throw ExecutorError.controlFailed(
                "Accessibility permission is required to control windows"
            )
        }
    }

    static func windows(of app: NSRunningApplication) throws -> [AXUIElement] {
        try requireAccessibility()
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        guard let value = attribute(axApp, kAXWindowsAttribute as CFString),
              let windows = value as? [AXUIElement] else {
            throw ExecutorError.controlFailed(
                "Could not access windows of \(app.localizedName ?? "application")"
            )
        }
        return windows
    }

    static func focusedWindow(of app: NSRunningApplication) throws -> AXUIElement? {
        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        if let focused = element(axApp, kAXFocusedWindowAttribute as CFString) {
            return focused
        }
        if let main = element(axApp, kAXMainWindowAttribute as CFString) {
            return main
        }
        return try windows(of: app).first
    }

    static func element(_ parent: AXUIElement, _ name: CFString) -> AXUIElement? {
        guard let value = attribute(parent, name),
              CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return unsafeDowncast(value, to: AXUIElement.self)
    }

    static func frame(of window: AXUIElement) -> CGRect? {
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

    static func set(frame: CGRect, of window: AXUIElement) {
        var point = frame.origin
        var dimensions = frame.size
        if let position = AXValueCreate(.cgPoint, &point),
           let size = AXValueCreate(.cgSize, &dimensions) {
            _ = AXUIElementSetAttributeValue(
                window, kAXPositionAttribute as CFString, position
            )
            _ = AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, size)
            _ = AXUIElementSetAttributeValue(
                window, kAXPositionAttribute as CFString, position
            )
        }
    }

    static func isNear(_ lhs: CGRect, _ rhs: CGRect) -> Bool {
        abs(lhs.width - rhs.width) <= rhs.width * 0.03
            && abs(lhs.height - rhs.height) <= rhs.height * 0.03
    }

    static func isMinimized(_ window: AXUIElement) -> Bool? {
        booleanAttribute(window, kAXMinimizedAttribute as String)
    }

    static func booleanAttribute(_ element: AXUIElement, _ name: String) -> Bool? {
        attribute(element, name as CFString) as? Bool
    }

    static func attribute(_ element: AXUIElement, _ name: CFString) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name, &value) == .success else {
            return nil
        }
        return value
    }
}
