import Cocoa
import Vision
import ImageIO
import CoreImage

@main struct OCRHelper {
    static func main() async {
        do {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            let words = try await Task.detached(priority: .userInitiated) { () throws -> [ReadWord] in
            guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { exit(2) }
            func recognize(_ target: CGImage) throws -> [ReadWord] {
                let request = VNRecognizeTextRequest()
                request.recognitionLevel = .fast
                request.recognitionLanguages = ["en-US"]
                request.minimumTextHeight = 0.006
                request.usesLanguageCorrection = false
                request.usesCPUOnly = true
                try VNImageRequestHandler(cgImage: target).perform([request])
                return (request.results ?? []).compactMap { observation -> ReadWord? in
                    guard let candidate = observation.topCandidates(1).first, candidate.confidence >= 0.15 else { return nil }
                    return ReadWord(text: candidate.string, rect: observation.boundingBox)
                }
            }
            let plain = try recognize(image)
            // A second pass enlarges and boosts the contrast of the central
            // dialog's gold serif lettering. Coordinates map back to the same
            // full-window image; these are observations, not fixed click points.
            let context = CIContext(options: [.useSoftwareRenderer: true])
            let areas = [CGRect(x: 0.2, y: 0.25, width: 0.6, height: 0.5), CGRect(x: 0.1, y: 0, width: 0.9, height: 0.23), CGRect(x: 0.25, y: 0.75, width: 0.5, height: 0.25)]
            var extra: [ReadWord] = []
            for area in areas {
                let pixels = CGRect(x: Double(image.width)*area.minX, y: Double(image.height)*(1-area.maxY), width: Double(image.width)*area.width, height: Double(image.height)*area.height)
                guard let crop = image.cropping(to: pixels) else { continue }
                let enhanced = CIImage(cgImage: crop)
                    .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0, kCIInputContrastKey: 2.2, kCIInputBrightnessKey: 0.05])
                    .transformed(by: CGAffineTransform(scaleX: 1.5, y: 1.5))
                guard let focused = context.createCGImage(enhanced, from: enhanced.extent) else { continue }
                extra += try recognize(focused).map { word in
                    ReadWord(text: word.text, rect: CGRect(x: area.minX+word.rect.minX*area.width, y: area.minY+word.rect.minY*area.height, width: word.rect.width*area.width, height: word.rect.height*area.height))
                }
            }
            return extra + plain
            }.value
            FileHandle.standardOutput.write(try JSONEncoder().encode(words))
        } catch { exit(3) }
    }
}
