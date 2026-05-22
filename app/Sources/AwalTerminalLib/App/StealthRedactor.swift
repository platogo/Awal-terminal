import Foundation

/// Redacts secret patterns from a string, returning ranges to mask.
enum StealthRedactor {
    static func redactedRanges(in text: String, patterns: [NSRegularExpression]) -> [NSRange] {
        var ranges: [NSRange] = []
        let nsText = text as NSString
        for pattern in patterns {
            let matches = pattern.matches(in: text, options: [], range: NSRange(location: 0, length: nsText.length))
            for match in matches {
                ranges.append(match.range)
            }
        }
        return ranges
    }
}
