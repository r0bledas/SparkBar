import Foundation
import AppKit
import Vision

public enum VisionOCRHelper {
    /// Runs Apple's built-in on-device Vision framework (`VNRecognizeTextRequest`) in ~30-50ms with zero extra dependencies.
    public static func recognizeText(from base64String: String) -> String {
        guard let data = Data(base64Encoded: base64String),
              let image = NSImage(data: data),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            return ""
        }
        return recognizeText(from: cgImage)
    }

    public static func recognizeText(from cgImage: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
        try? handler.perform([request])
        guard let observations = request.results else { return "" }
        let recognizedStrings = observations.compactMap { $0.topCandidates(1).first?.string }
        return recognizedStrings.joined(separator: "\n")
    }
}
