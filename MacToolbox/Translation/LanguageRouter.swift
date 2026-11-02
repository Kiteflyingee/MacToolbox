import Foundation
import NaturalLanguage

public enum LanguageRouter {
    public static func target(for text: String) throws -> TargetLanguage {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return try target(for: text, detectedLanguage: recognizer.dominantLanguage)
    }

    /// Explicit language input also makes the recognizer's nil/mixed-language fallback testable.
    public static func target(for text: String, detectedLanguage: NLLanguage?) throws -> TargetLanguage {
        guard text.unicodeScalars.contains(where: { CharacterSet.letters.contains($0) }) else { throw TranslationError.noText }
        if let detectedLanguage {
            return [.simplifiedChinese, .traditionalChinese].contains(detectedLanguage) ? .english : .simplifiedChinese
        }
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        let han = letters.filter { scalar in
            switch scalar.value {
            case 0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x323AF: true
            default: false
            }
        }.count
        return Double(han) / Double(letters.count) >= 0.5 ? .english : .simplifiedChinese
    }
}
