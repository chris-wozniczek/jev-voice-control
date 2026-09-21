import AVFoundation
import XCTest
@testable import JevVoice

final class WhisperSpeechEngineTests: XCTestCase {
    func testConvertHandlesConsecutiveBuffers() throws {
        guard
            let inputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 48_000,
                channels: 1,
                interleaved: false
            ),
            let outputFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000,
                channels: 1,
                interleaved: false
            ),
            let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else {
            throw XCTSkip("AVAudioConverter is unavailable")
        }
        converter.primeMethod = .none

        let first = try makeSineBuffer(format: inputFormat, phase: 0)
        let second = try makeSineBuffer(format: inputFormat, phase: .pi / 2)
        let firstSamples = WhisperSpeechEngine.convert(first, with: converter, to: outputFormat)
        let secondSamples = WhisperSpeechEngine.convert(second, with: converter, to: outputFormat)

        XCTAssertGreaterThan(firstSamples.count, 1_500)
        XCTAssertGreaterThan(secondSamples.count, 1_500)
    }

    private func makeSineBuffer(format: AVAudioFormat, phase: Float) throws -> AVAudioPCMBuffer {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800),
              let channel = buffer.floatChannelData?[0] else {
            throw XCTSkip("Unable to allocate AVAudioPCMBuffer")
        }
        buffer.frameLength = 4_800
        for index in 0..<Int(buffer.frameLength) {
            channel[index] = sin(Float(index) * 0.05 + phase)
        }
        return buffer
    }
}
