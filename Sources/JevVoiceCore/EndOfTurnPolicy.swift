import Foundation

public enum EndOfTurnDecision: Equatable {
    case finalize
    case wait(TimeInterval)
    case timer
}

public enum EndOfTurnPolicy {
    public static let finalizeAbove = 0.75
    public static let waitBelow = 0.35
    public static let minWait: TimeInterval = 4

    public static func decide(
        probability p: Double,
        silenceTimeout: TimeInterval
    ) -> EndOfTurnDecision {
        if p >= finalizeAbove {
            return .finalize
        }
        if p <= waitBelow {
            return .wait(max(silenceTimeout, minWait))
        }
        return .timer
    }
}
