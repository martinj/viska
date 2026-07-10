import XCTest
@testable import Viska

final class TranscriptReplacementEngineTests: XCTestCase {
    func testLongestOverlappingRuleWins() {
        let rules = [
            rule("paper trail", "papertrail"),
            rule("paper trail api", "papertrail-api"),
        ]

        let result = TranscriptReplacementEngine.apply(
            rules,
            to: "use the paper trail api and the paper trail"
        )

        XCTAssertEqual(result, "use the papertrail-api and the papertrail")
    }

    func testMatchesCaseInsensitivelyAndUsesLiteralReplacementCasing() {
        let result = TranscriptReplacementEngine.apply(
            [rule("paper trail", "papertrail")],
            to: "Paper Trail"
        )

        XCTAssertEqual(result, "papertrail")
    }

    func testDoesNotMatchInsideLargerWord() {
        let result = TranscriptReplacementEngine.apply(
            [rule("cat", "dog")],
            to: "concatenate cat scatter"
        )

        XCTAssertEqual(result, "concatenate dog scatter")
    }

    func testPunctuationEdgeTriggersRequireWholeTokenBoundaries() {
        let result = TranscriptReplacementEngine.apply(
            [
                rule("C++", "cpp"),
                rule("#tag", "hashtag"),
            ],
            to: "C++ C++x abc#tag #tag"
        )

        XCTAssertEqual(result, "cpp C++x abc#tag hashtag")
    }

    func testMatchesBeforePunctuation() {
        let result = TranscriptReplacementEngine.apply(
            [rule("Paper Trail", "papertrail")],
            to: "Paper Trail, please"
        )

        XCTAssertEqual(result, "papertrail, please")
    }

    func testMatchesFlexibleWhitespaceInPhrase() {
        let result = TranscriptReplacementEngine.apply(
            [rule("paper trail", "papertrail")],
            to: "paper\n  trail"
        )

        XCTAssertEqual(result, "papertrail")
    }

    func testMatchesSwedishCharacters() {
        let result = TranscriptReplacementEngine.apply(
            [rule("räksmörgås", "macka")],
            to: "En RÄKSMÖRGÅS tack"
        )

        XCTAssertEqual(result, "En macka tack")
    }

    func testDoesNotCascadeReplacementOutput() {
        let rules = [
            rule("paper trail", "papertrail"),
            rule("papertrail", "papertrail-api"),
        ]

        let result = TranscriptReplacementEngine.apply(rules, to: "paper trail")

        XCTAssertEqual(result, "papertrail")
    }

    func testEmptyRuleListReturnsInput() {
        XCTAssertEqual(TranscriptReplacementEngine.apply([], to: "unchanged"), "unchanged")
    }

    func testWhitespaceOnlyTriggerIsIgnored() {
        let result = TranscriptReplacementEngine.apply(
            [rule(" \n\t ", "ignored")],
            to: "unchanged"
        )

        XCTAssertEqual(result, "unchanged")
    }

    func testDuplicateNormalizedTriggersUseFirstRule() {
        let rules = [
            rule("Paper Trail", "first"),
            rule("paper   trail", "second"),
        ]

        let result = TranscriptReplacementEngine.apply(rules, to: "paper trail")

        XCTAssertEqual(result, "first")
    }

    private func rule(_ trigger: String, _ replacement: String) -> WordReplacement {
        WordReplacement(id: UUID(), trigger: trigger, replacement: replacement)
    }
}
