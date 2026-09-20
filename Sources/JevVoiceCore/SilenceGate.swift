import Foundation

public struct SilenceGate {
    private var lastNormalizedPartial = ""

    public init() {}

    public mutating func shouldReschedule(partial: String) -> Bool {
        let normalized = Self.normalize(partial)
        guard !normalized.isEmpty else { return false }
        defer { lastNormalizedPartial = normalized }
        return normalized != lastNormalizedPartial
    }

    public mutating func reset() {
        lastNormalizedPartial = ""
    }

    private static func normalize(_ text: String) -> String {
        let withoutPunctuation = text.unicodeScalars.filter {
            !CharacterSet.punctuationCharacters.contains($0)
        }
        return String(String.UnicodeScalarView(withoutPunctuation))
            .lowercased()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }
}
