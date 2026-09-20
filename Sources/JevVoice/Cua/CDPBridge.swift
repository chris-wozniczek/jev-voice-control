import Foundation

struct CDPTarget: Equatable {
    let id: String
    let title: String
    let url: String
    let type: String
    let webSocketDebuggerURL: URL
}

actor CDPBridge {
    static let shared = CDPBridge()

    private var availability: [Int: (expires: Date, value: Bool)] = [:]

    func isAvailable(port: Int) async -> Bool {
        if let cached = availability[port], cached.expires > Date() {
            return cached.value
        }
        guard let url = URL(string: "http://127.0.0.1:\(port)/json/version") else {
            availability[port] = (Date().addingTimeInterval(5), false)
            return false
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 0.4
        let value: Bool
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            value = (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
        } catch {
            value = false
        }
        availability[port] = (Date().addingTimeInterval(5), value)
        return value
    }

    func elements(port: Int, windowTitle: String) async throws -> [CuaElement]? {
        guard let target = try await target(port: port, windowTitle: windowTitle) else {
            return nil
        }
        let expression = """
        (() => { const sel='a[href],button,input,textarea,select,[role=button],[role=link],[role=tab],[role=menuitem],[role=checkbox],[role=textbox],[contenteditable=true]';
          const out=[]; let n=0; for (const el of document.querySelectorAll(sel)) { const r=el.getBoundingClientRect();
          if (r.width<2||r.height<2||r.bottom<0||r.top>innerHeight) continue; n++; el.setAttribute('data-jev', String(n));
          const label=(el.getAttribute('aria-label')||el.innerText||el.value||el.placeholder||el.title||'').trim().slice(0,120);
          out.push({n, tag:el.tagName.toLowerCase(), type:el.getAttribute('type')||'', role:el.getAttribute('role')||'', contenteditable:el.getAttribute('contenteditable')||'', label, value:(el.value||'').slice(0,80)});
          if (n>=200) break; } return JSON.stringify(out); })()
        """
        guard let value = try await evaluate(expression, target: target),
              let data = value.data(using: .utf8),
              let json = try? JSONDecoder().decode([JSONValue].self, from: data) else {
            return []
        }
        return json.compactMap { $0.objectValue }.compactMap(Self.mapElement)
    }

    func click(port: Int, windowTitle: String, token: String) async throws {
        guard let target = try await target(port: port, windowTitle: windowTitle) else {
            throw AgentError.api("That control is no longer on the page")
        }
        let number = try elementNumber(token)
        let expression = """
        (() => { const e=document.querySelector('[data-jev="\(number)"]'); if(!e) return 'missing'; e.scrollIntoView({block:'center'}); e.focus(); e.click(); return 'ok'; })()
        """
        guard try await evaluate(expression, target: target) == "ok" else {
            throw AgentError.api("That control is no longer on the page")
        }
    }

    func type(port: Int, windowTitle: String, token: String, text: String) async throws {
        guard let target = try await target(port: port, windowTitle: windowTitle) else {
            throw AgentError.api("That control is no longer on the page")
        }
        let number = try elementNumber(token)
        let expression = """
        (() => { const e=document.querySelector('[data-jev="\(number)"]'); if(!e) return 'missing'; e.focus(); return 'ok'; })()
        """
        guard try await evaluate(expression, target: target) == "ok" else {
            throw AgentError.api("That control is no longer on the page")
        }
        _ = try await command(
            target: target,
            method: "Input.insertText",
            params: ["text": .string(text)]
        )
    }

    static func selectTarget(targets: [CDPTarget], windowTitle: String) -> CDPTarget? {
        let requested = windowTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let pages = targets.filter { $0.type == "page" }
        guard !requested.isEmpty else { return pages.first }
        if let exact = pages.first(where: {
            $0.title.trimmingCharacters(in: .whitespacesAndNewlines)
                .caseInsensitiveCompare(requested) == .orderedSame
        }) {
            return exact
        }
        return pages.first { target in
            let title = target.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return false }
            let normalizedTitle = title.lowercased()
            let normalizedRequested = requested.lowercased()
            return normalizedTitle == normalizedRequested
                || normalizedRequested.hasPrefix(normalizedTitle)
                || normalizedRequested.hasSuffix(normalizedTitle)
                || normalizedTitle.hasPrefix(normalizedRequested)
                || normalizedTitle.hasSuffix(normalizedRequested)
        }
    }

    static func mapElement(json: [String: JSONValue]) -> CuaElement? {
        guard let number = json["n"]?.intValue else { return nil }
        let tag = json["tag"]?.stringValue?.lowercased() ?? ""
        let type = json["type"]?.stringValue?.lowercased() ?? ""
        let explicitRole = json["role"]?.stringValue?.lowercased() ?? ""
        let contentEditable = json["contenteditable"]?.boolValue == true
            || json["contenteditable"]?.stringValue?.lowercased() == "true"
        let role: String
        switch explicitRole {
        case "button": role = "AXButton"
        case "link": role = "AXLink"
        case "tab": role = "AXTab"
        case "menuitem": role = "AXMenuItem"
        case "checkbox": role = "AXCheckBox"
        case "textbox": role = tag == "div" || tag == "p" ? "AXTextArea" : "AXTextField"
        default:
            switch tag {
            case "a": role = "AXLink"
            case "button": role = "AXButton"
            case "textarea": role = "AXTextArea"
            case "select": role = "AXPopUpButton"
            case "input":
                switch type {
                case "checkbox": role = "AXCheckBox"
                case "button", "submit", "reset": role = "AXButton"
                default: role = "AXTextField"
                }
            default:
                guard contentEditable else { return nil }
                role = "AXTextArea"
            }
        }
        return CuaElement(
            token: "cdp:\(number)",
            role: role,
            label: json["label"]?.stringValue ?? "",
            value: json["value"]?.stringValue
        )
    }

    private func target(port: Int, windowTitle: String) async throws -> CDPTarget? {
        guard let url = URL(string: "http://127.0.0.1:\(port)/json") else {
            throw AgentError.api("Invalid Chrome DevTools address")
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) == true else {
            throw AgentError.api("Chrome DevTools returned an invalid target list")
        }
        let values = try JSONDecoder().decode([JSONValue].self, from: data)
        let targets = values.compactMap { value -> CDPTarget? in
            guard let object = value.objectValue,
                  let id = object["id"]?.stringValue,
                  let title = object["title"]?.stringValue,
                  let url = object["url"]?.stringValue,
                  let type = object["type"]?.stringValue,
                  let socket = object["webSocketDebuggerUrl"]?.stringValue,
                  let webSocketURL = URL(string: socket) else { return nil }
            return CDPTarget(
                id: id,
                title: title,
                url: url,
                type: type,
                webSocketDebuggerURL: webSocketURL
            )
        }
        return Self.selectTarget(targets: targets, windowTitle: windowTitle)
    }

    private func evaluate(_ expression: String, target: CDPTarget) async throws -> String? {
        let response = try await command(
            target: target,
            method: "Runtime.evaluate",
            params: [
                "expression": .string(expression),
                "returnByValue": .bool(true),
            ]
        )
        return response["result"]?["result"]?["value"]?.stringValue
    }

    private func command(
        target: CDPTarget,
        method: String,
        params: [String: JSONValue] = [:]
    ) async throws -> [String: JSONValue] {
        let task = URLSession.shared.webSocketTask(with: target.webSocketDebuggerURL)
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }
        let request: JSONValue = .object([
            "id": .number(1),
            "method": .string(method),
            "params": .object(params),
        ])
        let data = try JSONEncoder().encode(request)
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
        return try await receive(task: task, id: 1)
    }

    private func receive(
        task: URLSessionWebSocketTask,
        id: Int
    ) async throws -> [String: JSONValue] {
        try await withThrowingTaskGroup(of: [String: JSONValue].self) { group in
            group.addTask {
                while true {
                    let message = try await task.receive()
                    let data: Data
                    switch message {
                    case .string(let value):
                        data = Data(value.utf8)
                    case .data(let value):
                        data = value
                    @unknown default:
                        continue
                    }
                    let object = try JSONDecoder().decode(JSONValue.self, from: data).objectValue ?? [:]
                    if object["id"]?.intValue == id {
                        return object
                    }
                }
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 3_000_000_000)
                throw CuaDriverError.timeout
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    private func elementNumber(_ token: String) throws -> Int {
        guard let number = Int(token.dropFirst("cdp:".count)) else {
            throw AgentError.api("Invalid Chrome DevTools element token")
        }
        return number
    }
}
