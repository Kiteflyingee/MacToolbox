import Foundation
import Vision

public actor OCRService {
    public init() {}
    public func recognize(png: Data) throws -> String {
        guard png.count <= AppLimits.historyQueueBytes else { throw CoreError.contentTooLarge }
        try Task.checkCancellation()
        let image = try ImageCodec.decode(png)
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let supported = try request.supportedRecognitionLanguages()
        request.recognitionLanguages = ["en-US", "zh-Hans", "zh-Hant", "ja-JP", "ko-KR"].filter(supported.contains)
        try VNImageRequestHandler(cgImage: image).perform([request])
        try Task.checkCancellation()
        let observations = (request.results ?? []).sorted {
            let a = Int(($0.boundingBox.midY * 100).rounded()), b = Int(($1.boundingBox.midY * 100).rounded())
            return a == b ? $0.boundingBox.minX < $1.boundingBox.minX : a > b
        }
        let text = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw TranslationError.noText }
        try ChatRequestBuilder.validateText(text)
        return text
    }
}
