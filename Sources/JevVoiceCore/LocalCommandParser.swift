import Foundation

public enum LocalCommandParser {
    public static func parse(
        clause: String,
        installedApps: [String],
        aliases: [String: String],
        frontmostApp: String?,
        siteResolver: SiteResolver = SiteResolver(sites: SiteResolver.defaultSites),
        defaultBrowser: String = "Google Chrome"
    ) -> Decision? {
        let trimmed = clause.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let brief = SlotExtractor.composeRequest(from: trimmed) {
            let site = siteResolver.site(in: trimmed, installedApps: installedApps)
            return Decision(
                clause: trimmed, action: .dictate,
                targetApp: site == nil ? nil : SlotExtractor.searchBrowser(from: trimmed) ?? defaultBrowser,
                siteHost: site?.host,
                query: brief,
                composes: true, confidence: 0.9, model: "local"
            )
        }

        if trimmed.range(
            of: #"^\s*(?:type(?:\s+(?:in|out))?|write|dictate|say|enter)\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil,
           let text = SlotExtractor.dictationText(from: trimmed) {
            return Decision(
                clause: trimmed, action: .dictate, text: text,
                confidence: 0.9, model: "local"
            )
        }

        if trimmed.range(
            of: #"^(check(?:\s+out)?|tell\s+me|find(?:\s+out)?|google|search(?:\s+for)?|look(?:\s+at|\s+up)?|who|what|when|where|how)\b"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil,
           let query = SlotExtractor.searchQuery(from: trimmed)
                ?? SlotExtractor.fallbackSearchQuery(from: trimmed) {
            return Decision(
                clause: trimmed, action: .webSearch,
                targetApp: SlotExtractor.searchBrowser(from: trimmed),
                query: query, confidence: 0.9, model: "local"
            )
        }

        if let url = SlotExtractor.url(from: trimmed),
           trimmed.range(of: #"^(go to|open)\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return Decision(
                clause: trimmed, action: .openURL, url: url,
                confidence: 0.9, model: "local"
            )
        }

        if let system = parseSystem(trimmed) {
            return Decision(
                clause: trimmed, action: .system, systemAction: system.action,
                percent: system.percent, confidence: 0.9, model: "local"
            )
        }

        guard let verb = AppMatcher.verbAction(clause: trimmed) else { return nil }
        if trimmed.lowercased().range(
            of: #"\s+or\s+"#, options: .regularExpression
        ) != nil {
            return nil
        }
        let localMatch = AppMatcher.match(
            clause: trimmed, installedApps: installedApps, aliases: aliases
        )
        if let localMatch, localMatch.confidence == 0.5 { return nil }
        if let localMatch {
            return Decision(
                clause: trimmed, action: verb, targetApp: localMatch.app,
                spokenTarget: AppMatcher.spokenTarget(from: trimmed),
                confidence: max(0.8, localMatch.confidence), model: "local"
            )
        }
        if verb != .openApp,
           AppMatcher.refersToFrontmostLocally(clause: trimmed),
           let frontmostApp {
            return Decision(
                clause: trimmed, action: verb, targetApp: frontmostApp,
                spokenTarget: AppMatcher.spokenTarget(from: trimmed),
                confidence: 0.9, model: "local"
            )
        }
        return nil
    }

    private static func parseSystem(_ clause: String) -> (action: SystemAction, percent: Int?)? {
        let lowered = clause.lowercased()
        if lowered.range(of: #"^unmute\b"#, options: .regularExpression) != nil {
            return (.unmute, nil)
        }
        if lowered.range(of: #"^mute\b"#, options: .regularExpression) != nil {
            return (.mute, nil)
        }
        if lowered.range(of: #"^volume\s+up\b"#, options: .regularExpression) != nil {
            return (.volumeUp, nil)
        }
        if lowered.range(of: #"^volume\s+down\b"#, options: .regularExpression) != nil {
            return (.volumeDown, nil)
        }
        if lowered.range(of: #"^volume(?:\s+to)?\s+\d{1,3}\s*(?:percent|%)?\b"#,
                         options: .regularExpression) != nil,
           let percent = SlotExtractor.numberPercent(from: clause) {
            return (.volumeSet, percent)
        }
        if lowered.range(of: #"^lock(?:\s+the)?\s+screen\b"#,
                         options: .regularExpression) != nil {
            return (.lockScreen, nil)
        }
        if lowered.range(of: #"^take\s+a\s+screenshot\b"#,
                         options: .regularExpression) != nil {
            return (.screenshot, nil)
        }
        return nil
    }
}
