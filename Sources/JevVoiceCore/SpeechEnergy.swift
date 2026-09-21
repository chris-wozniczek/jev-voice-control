import Foundation

public enum SpeechEnergy {
    public static func rms(_ samples: [Float]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let meanSquare = samples.reduce(0.0) { total, sample in
            total + Double(sample) * Double(sample)
        } / Double(samples.count)
        return sqrt(meanSquare)
    }

    public static func isVoiced(rms: Double, noiseFloor: Double) -> Bool {
        rms > max(0.01, noiseFloor * 4)
    }

    public static func updatedNoiseFloor(current: Double?, rms: Double) -> Double {
        max(0.002, min(current ?? rms, rms))
    }
}
