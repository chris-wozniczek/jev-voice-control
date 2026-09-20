import CoreGraphics
import Foundation
import Vision

struct OCRObservation {
    let text: String
    let box: CGRect
    let confidence: Float
}

struct OCRHit {
    let element: CuaElement
    let point: CGPoint
}

enum OCRReader {
    static func hits(
        from observations: [OCRObservation],
        windowFrame: CGRect
    ) -> [OCRHit] {
        var seen = Set<String>()
        var hits: [OCRHit] = []

        for observation in observations {
            guard observation.confidence >= 0.3 else { continue }
            let text = observation.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.filter({ !$0.isWhitespace }).count >= 2 else { continue }

            let point = CGPoint(
                x: windowFrame.minX + observation.box.midX * windowFrame.width,
                y: windowFrame.minY + (1 - observation.box.midY) * windowFrame.height
            )
            let roundedPoint = "\(Int(point.x.rounded())):\(Int(point.y.rounded()))"
            let key = "\(text)\u{1f}\(roundedPoint)"
            guard seen.insert(key).inserted else { continue }

            let token = "ocr:\(hits.count + 1)"
            hits.append(OCRHit(
                element: CuaElement(
                    token: token,
                    role: "AXStaticText",
                    label: text,
                    value: nil
                ),
                point: point
            ))
            if hits.count == 150 { break }
        }

        return hits
    }

    static func scan(windowFrame: CGRect) -> [OCRHit]? {
        guard let image = CGWindowListCreateImage(
            windowFrame,
            .optionOnScreenOnly,
            kCGNullWindowID,
            [.bestResolution]
        ) else {
            return nil
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: image)
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        let observations = (request.results ?? []).compactMap { observation -> OCRObservation? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return OCRObservation(
                text: candidate.string,
                box: observation.boundingBox,
                confidence: candidate.confidence
            )
        }
        let hits = hits(from: observations, windowFrame: windowFrame)
        return hits.isEmpty ? nil : hits
    }
}
