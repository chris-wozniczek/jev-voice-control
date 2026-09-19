import Foundation

public enum HearingSettings {
    public static let defaultSilenceTimeout = 2.5

    public static func constrainedSilenceTimeout(_ value: Double) -> Double {
        min(5, max(1, value))
    }
}
