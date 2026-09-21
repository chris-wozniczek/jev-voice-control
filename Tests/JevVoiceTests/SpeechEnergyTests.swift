import XCTest
@testable import JevVoiceCore

final class SpeechEnergyTests: XCTestCase {
    func testSilenceIsNotVoiced() {
        let samples = Array(repeating: Float(0), count: 1_600)
        let rms = SpeechEnergy.rms(samples)

        XCTAssertEqual(rms, 0)
        XCTAssertFalse(SpeechEnergy.isVoiced(rms: rms, noiseFloor: 0.002))
    }

    func testPointOneAmplitudeSineIsVoiced() {
        let samples = (0..<1_600).map {
            Float(sin(Double($0) * 2 * .pi / 80) * 0.1)
        }
        let rms = SpeechEnergy.rms(samples)

        XCTAssertEqual(rms, 0.0707, accuracy: 0.001)
        XCTAssertTrue(SpeechEnergy.isVoiced(rms: rms, noiseFloor: 0.002))
    }

    func testNoiseFloorAdaptsToQuietInputWithMinimumFloor() {
        let first = SpeechEnergy.updatedNoiseFloor(current: nil, rms: 0.01)
        let adapted = SpeechEnergy.updatedNoiseFloor(current: first, rms: 0.004)
        let floored = SpeechEnergy.updatedNoiseFloor(current: adapted, rms: 0)

        XCTAssertEqual(first, 0.01, accuracy: 0.0001)
        XCTAssertEqual(adapted, 0.004, accuracy: 0.0001)
        XCTAssertEqual(floored, 0.002, accuracy: 0.0001)
    }
}
