import Foundation
import JarvisCore

/// English and Spanish number words (folded: lowercase, no diacritics) up to 99.
enum NumberWords {
    private static let units: [String: Int] = [
        // English
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9,
        "ten": 10, "eleven": 11, "twelve": 12, "thirteen": 13, "fourteen": 14, "fifteen": 15, "sixteen": 16,
        "seventeen": 17, "eighteen": 18, "nineteen": 19,
        // Spanish
        "cero": 0, "uno": 1, "un": 1, "una": 1, "dos": 2, "tres": 3, "cuatro": 4, "cinco": 5, "seis": 6, "siete": 7,
        "ocho": 8, "nueve": 9, "diez": 10, "once": 11, "doce": 12, "trece": 13, "catorce": 14, "quince": 15,
        "dieciseis": 16, "diecisiete": 17, "dieciocho": 18, "diecinueve": 19,
    ]

    private static let tens: [String: Int] = [
        "twenty": 20, "thirty": 30, "forty": 40, "fifty": 50, "sixty": 60, "seventy": 70, "eighty": 80, "ninety": 90,
        "veinte": 20, "treinta": 30, "cuarenta": 40, "cincuenta": 50, "sesenta": 60, "setenta": 70, "ochenta": 80, "noventa": 90,
    ]

    private static let spanishTwenties: [String: Int] = [
        "veintiuno": 21, "veintiun": 21, "veintiuna": 21, "veintidos": 22, "veintitres": 23, "veinticuatro": 24,
        "veinticinco": 25, "veintiseis": 26, "veintisiete": 27, "veintiocho": 28, "veintinueve": 29,
    ]

    /// A regular-expression fragment (no capture groups) matching digits or number words.
    static let fragment: String = {
        let unitWords = units.keys.sorted { $0.count > $1.count }
        let tensWords = tens.keys.sorted { $0.count > $1.count }
        let twenties = spanishTwenties.keys.sorted { $0.count > $1.count }
        let unitAlternation = unitWords.joined(separator: "|")
        let tensAlternation = tensWords.joined(separator: "|")
        let twentiesAlternation = twenties.joined(separator: "|")
        // tens with optional unit: "twenty five", "twenty-five", "treinta y cinco"
        let composite = "(?:\(tensAlternation))(?:(?:\\s+y\\s+|[-\\s])(?:\(unitAlternation)))?"
        return "(?:\\d{1,4}|\(twentiesAlternation)|\(composite)|\(unitAlternation))"
    }()

    /// Parses digits or number words ("12", "twelve", "veinticinco", "twenty five", "treinta y cinco").
    static func parse(_ text: String) -> Int? {
        let cleaned = TextFolding.fold(text).trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty else { return nil }
        if let value = Int(cleaned) { return value }
        if let value = units[cleaned] { return value }
        if let value = spanishTwenties[cleaned] { return value }
        if let value = tens[cleaned] { return value }
        let separators = CharacterSet(charactersIn: " -")
        let parts = cleaned.components(separatedBy: separators).filter { !$0.isEmpty }
        if parts.count == 2, let ten = tens[parts[0]], let unit = units[parts[1]], unit >= 1, unit <= 9 { return ten + unit }
        if parts.count == 3, let ten = tens[parts[0]], parts[1] == "y", let unit = units[parts[2]], unit >= 1, unit <= 9 { return ten + unit }
        return nil
    }
}
