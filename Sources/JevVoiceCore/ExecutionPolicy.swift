import Foundation

public enum ExecutionPolicy {
    public enum Verdict: Equatable {
        case run
        case confirm(reason: String)
        case reject(reason: String)
    }

    public static func verdict(
        for decisions: [Decision],
        alwaysConfirm: Bool,
        previewGeneratedText: Bool = false,
        policy: SafetyPolicy? = nil,
        transcript: String? = nil
    ) -> Verdict {
        if let policyVerdict = policy?.verdict(
            for: transcript ?? decisions.map(\.clause).joined(separator: " ")
        ) {
            switch policyVerdict {
            case .reject(let reason):
                return .reject(reason: reason)
            case .confirm(let reason):
                return .confirm(reason: reason)
            }
        }
        if decisions.contains(where: { $0.riskTier == .destructive }) {
            return .confirm(reason: "This sounds hard to undo — confirm?")
        }
        if previewGeneratedText,
           let generated = decisions.first(where: { $0.composes && $0.generatedText != nil })?.generatedText {
            let preview = String(generated.prefix(120))
            let suffix = generated.count > 120 ? "…" : ""
            return .confirm(reason: "Type this? \(preview)\(suffix)")
        }
        if alwaysConfirm {
            return .confirm(reason: "Ask before running is on")
        }
        for decision in decisions where Action.appTargeted.contains(decision.action) {
            guard let app = decision.targetApp else {
                return .reject(reason: "I didn't catch which app")
            }
            if decision.confidence <= 0.5 {
                let names = decision.targetAppProbabilities
                    .sorted {
                        if $0.value != $1.value { return $0.value > $1.value }
                        return $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending
                    }
                    .prefix(2)
                    .map(\.key)
                let candidates = names.isEmpty ? app : names.joined(separator: " or ")
                return .confirm(reason: "Ambiguous app: \(candidates)")
            }
        }
        if decisions.contains(where: {
            !$0.composes && $0.action != .none && $0.action != .uiTask && $0.confidence < 0.4
        }) {
            return .confirm(reason: "Low confidence")
        }
        return .run
    }
}
