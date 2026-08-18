//
//  ThinkTagFilterTests.swift
//  mimika-ai-voice-studioTests
//
//  A cast member reading its own chain-of-thought aloud is the failure these guard against, so the split-tag cases matter as much as the simple ones: tokens arrive a few characters at a time and a tag is almost never delivered whole.
//

import XCTest
@testable import mimika_ai_voice_studio

final class ThinkTagFilterTests: XCTestCase {

    /// Feeds a whole response one delta at a time and returns everything the filter let through.
    private func run(_ deltas: [String]) -> String {
        var filter = ThinkTagFilter()
        var out = ""
        for delta in deltas {
            out += filter.filter(delta)
        }
        out += filter.flush()
        return out
    }

    // MARK: - Pass-through

    func test_textWithoutTagsPassesThroughUnchanged() {
        XCTAssertEqual(run(["Hello ", "there, ", "Ava."]), "Hello there, Ava.")
    }

    func test_angleBracketsThatAreNotTagsSurvive() {
        XCTAssertEqual(run(["a < b ", "and c > d"]), "a < b and c > d")
    }

    // MARK: - Stripping

    func test_thinkSpanIsRemoved() {
        XCTAssertEqual(
            run(["<think>weighing it up</think>", "The answer is yes."]),
            "The answer is yes."
        )
    }

    func test_textBeforeAndAfterASpanIsKept() {
        XCTAssertEqual(
            run(["Well. <think>hmm</think> I agree."]),
            "Well.  I agree."
        )
    }

    func test_multipleSpansAreAllRemoved() {
        XCTAssertEqual(
            run(["<think>one</think>A<think>two</think>B"]),
            "AB"
        )
    }

    /// The real streaming shape: tags arrive split across deltas.
    func test_openingTagSplitAcrossDeltasIsStillDetected() {
        XCTAssertEqual(
            run(["<th", "ink>", "secret ", "reasoning", "</thi", "nk>", "Spoken line."]),
            "Spoken line."
        )
    }

    func test_closingTagSplitOneCharacterPerDeltaIsStillDetected() {
        let deltas = ["<think>x"] + "</think>".map(String.init) + ["Done."]
        XCTAssertEqual(run(deltas), "Done.")
    }

    // MARK: - Partial holds

    /// A partial tag that never completes is ordinary text, released on flush.
    func test_unfinishedPartialTagIsReleasedAtEndOfStream() {
        XCTAssertEqual(run(["Grade: A<thi"]), "Grade: A<thi")
    }

    /// A span the model never closed was still mid-thought when it was cut off — none of it is speakable.
    func test_unclosedThinkSpanIsDiscarded() {
        XCTAssertEqual(run(["<think>still going when the budget ran out"]), "")
    }

    /// The filter must not emit a partial tag early, or the caller speaks "<thi".
    func test_partialTagIsHeldBackUntilResolved() {
        var filter = ThinkTagFilter()
        XCTAssertEqual(filter.filter("Yes<thi"), "Yes", "partial tag must not be emitted yet")
        XCTAssertEqual(filter.filter("nk>hidden</think> done"), " done")
    }

    // MARK: - Reuse

    func test_flushResetsStateForTheNextStream() {
        var filter = ThinkTagFilter()
        _ = filter.filter("<think>unclosed")
        XCTAssertEqual(filter.flush(), "")
        XCTAssertEqual(filter.filter("fresh stream"), "fresh stream")
    }
}
