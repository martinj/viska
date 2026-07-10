import Foundation

enum TranscriptReplacementEngine {
    static func apply(_ rules: [WordReplacement], to text: String) -> String {
        let usableRules = rules
            .enumerated()
            .compactMap { offset, rule -> UsableRule? in
                let trigger = rule.trigger.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trigger.isEmpty else { return nil }

                return UsableRule(
                    offset: offset,
                    trigger: trigger,
                    normalizedTrigger: normalize(trigger),
                    replacement: rule.replacement
                )
            }

        guard !usableRules.isEmpty else { return text }

        var replacementsByTrigger: [String: String] = [:]
        for rule in usableRules where replacementsByTrigger[rule.normalizedTrigger] == nil {
            replacementsByTrigger[rule.normalizedTrigger] = rule.replacement
        }

        let alternation = usableRules
            .sorted {
                if $0.normalizedTrigger.count == $1.normalizedTrigger.count {
                    return $0.offset < $1.offset
                }

                return $0.normalizedTrigger.count > $1.normalizedTrigger.count
            }
            .map { pattern(for: $0.trigger) }
            .joined(separator: "|")

        let expression = try! NSRegularExpression(
            pattern: "(?<![\\p{L}\\p{N}_])(?:\(alternation))(?![\\p{L}\\p{N}_])",
            options: [.caseInsensitive, .useUnicodeWordBoundaries]
        )

        let matches = expression.matches(
            in: text,
            range: NSRange(text.startIndex..<text.endIndex, in: text)
        )

        guard !matches.isEmpty else { return text }

        var processedText = ""
        var currentIndex = text.startIndex

        for match in matches {
            guard let range = Range(match.range, in: text) else { continue }

            processedText += text[currentIndex..<range.lowerBound]

            let matchedText = String(text[range])
            processedText += replacementsByTrigger[normalize(matchedText)] ?? matchedText

            currentIndex = range.upperBound
        }

        processedText += text[currentIndex..<text.endIndex]
        return processedText
    }

    private static func pattern(for trigger: String) -> String {
        let escapedPattern = NSRegularExpression.escapedPattern(for: trigger)
        let flexibleWhitespacePattern = whitespaceExpression.stringByReplacingMatches(
            in: escapedPattern,
            range: NSRange(location: 0, length: escapedPattern.utf16.count),
            withTemplate: "\\\\s+"
        )

        return flexibleWhitespacePattern
    }

    private static func normalize(_ text: String) -> String {
        text
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
            .lowercased()
    }

    private static let whitespaceExpression = try! NSRegularExpression(pattern: "\\s+")
}

private struct UsableRule {
    let offset: Int
    let trigger: String
    let normalizedTrigger: String
    let replacement: String
}
