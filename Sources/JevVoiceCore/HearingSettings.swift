import Foundation

public enum HearingSettings {
    public static let defaultSilenceTimeout = 2.5
    public static let pauseProbeDelay: TimeInterval = 0.6

    public static func constrainedSilenceTimeout(_ value: Double) -> Double {
        min(5, max(1, value))
    }
}
