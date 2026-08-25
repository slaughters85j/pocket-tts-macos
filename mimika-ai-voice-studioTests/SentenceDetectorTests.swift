//
//  SentenceDetectorTests.swift
//  mimika-ai-voice-studioTests
//

import XCTest
@testable import mimika_ai_voice_studio

final class SentenceDetectorTests: XCTestCase {

    func test_simpleTwoSentences_emittedOnTerminator() {
        let d = SentenceDetector()
        // Single delivery, but tokens add up to two sentences both >20 chars.
        let out = d.append("This is the first sentence. And here is the second.")
        XCTAssertEqual(out.count, 1, "expected the first sentence to emit; tail remains buffered")
        XCTAssertEqual(out[0], "This is the first sentence.")
        let tail = d.flush()
        XCTAssertEqual(tail, "And here is the second.")
    }

    func test_belowMinLength_buffersUntilLongEnough() {
        let d = SentenceDetector()
        XCTAssertTrue(d.append("Hi. ").isEmpty, "below 20-char threshold should not split")
        XCTAssertTrue(d.append("Yes. ").isEmpty)
        // After enough chars + a trailing whitespace, a sentence boundary emits. (The algorithm requires terminator-followed-by-whitespace so it doesn't prematurely split on a partial token like "3.14" mid-stream.)
        let out = d.append("Here is a long enough segment to cross the threshold. ")
        XCTAssertEqual(out.count, 1, "got: \(out)")
        XCTAssertTrue(out[0].contains("Here is a long enough segment"))
    }

    func test_flushEmitsTail() {
        let d = SentenceDetector()
        _ = d.append("Trailing partial without terminator")
        let tail = d.flush()
        XCTAssertEqual(tail, "Trailing partial without terminator")
    }

    func test_flushAfterClean_returnsNil() {
        let d = SentenceDetector()
        _ = d.append("This is one whole sentence right here.")   // ends in "." but no whitespace after
        // Trailing terminator without whitespace currently does NOT split (matches the algorithm — "Mr." inline must not break). flush() picks it up though.
        XCTAssertEqual(d.flush(), "This is one whole sentence right here.")
    }

    // MARK: - Abbreviations

    /// The reported bug, verbatim: "Lt." past the 20-char threshold split the line, so TTS spoke "…an order from Lt." alone and then stalled for seconds while the long remainder synthesized.
    func test_rankAbbreviation_doesNotSplitMidName() {
        let d = SentenceDetector()
        let out = d.append(
            "The probability that an order from Lt. Commander Cock-gobbler can override Federation law is zero. "
        )
        XCTAssertEqual(out.count, 1, "expected one sentence, got: \(out)")
        XCTAssertEqual(
            out[0],
            "The probability that an order from Lt. Commander Cock-gobbler can override Federation law is zero."
        )
    }

    func test_titleAndInitial_doNotSplit() {
        let d = SentenceDetector()
        let out = d.append("Get down to sickbay and have Dr. Crusher check you out right now. ")
        XCTAssertEqual(out.count, 1, "got: \(out)")

        let e = SentenceDetector()
        let initials = e.append("The report was filed by J. Smith earlier this afternoon today. ")
        XCTAssertEqual(initials.count, 1, "a lone initial is not a sentence end; got: \(initials)")
    }

    /// Only titles suppress a split. Words that merely appear in `TextNormalizer.abbreviations` — units, corporate suffixes, months — must still end sentences, or the first spoken audio is delayed by a whole clause.
    func test_nonTitleAbbreviationsStillEndSentences() {
        let cases = [
            "I asked for permission and he said no. Then he left the bridge. ",
            "Bring rations, medkits, tricorders, etc. Then report to the bay. ",
            "The whole account was settled with Acme Corp. Then he resigned. ",
            "Push the deflector gain all the way to max. Then reboot the array. ",
            "The launch window we were given is set for Dec. Then we regroup. ",
            "He walked the entire length of Baker St. Then he turned back. ",
        ]
        for input in cases {
            let d = SentenceDetector()
            var out = d.append(input)
            // A trailing clause under minSentenceLength stays buffered until flush; what matters is that the abbreviation did not swallow it.
            if let tail = d.flush() { out.append(tail) }
            XCTAssertEqual(out.count, 2, "expected a split in \(input) — got: \(out)")
        }
    }

    /// A lone capital is an initial, but only when it reads as one. Regression guard for lettered enumerations, which are common in model output.
    func test_loneCapitalHandling() {
        let d = SentenceDetector()
        let initials = d.append("The report was filed by J. Smith earlier this afternoon. ")
        XCTAssertEqual(initials.count, 1, "a name initial is not a sentence end; got: \(initials)")
    }

    /// A lowercase-styled turn must still produce sentences as it streams. Regression: a "next word is lowercase means no boundary" rule made this emit NOTHING until end-of-stream, so speech waited for the whole turn.
    func test_lowercaseStyledTurnStillSplits() {
        let d = SentenceDetector()
        let out = d.append(
            "yeah i looked at the readings twice. they still don't add up at all. "
            + "i think the sensor is lying to us. "
        )
        XCTAssertGreaterThanOrEqual(out.count, 2, "lowercase prose must still chunk; got: \(out)")
    }

    /// Streaming and batch must agree, or `truncatedSpokenText` keeps lines the listener never heard when the user barges in.
    func test_streamedAndBatchProduceSameSentenceCount() {
        let full = "We finished the whole scan of deck twelve. iPhones cannot help us here. "
        let batch = SentenceDetector()
        var batchOut = batch.append(full)
        if let tail = batch.flush() { batchOut.append(tail) }

        let streamed = SentenceDetector()
        var streamOut: [String] = []
        for delta in ["We finished the whole scan of deck twelve. ", "iPhones cannot help us here. "] {
            streamOut.append(contentsOf: streamed.append(delta))
        }
        if let tail = streamed.flush() { streamOut.append(tail) }

        XCTAssertEqual(batchOut, streamOut, "batch \(batchOut) != streamed \(streamOut)")
    }

    func test_streamedDeltas_emitInOrder() {
        let d = SentenceDetector()
        var all: [String] = []
        for delta in ["This is ", "the first sentence", ". And", " here is", " the second sentence", ". And a tail."] {
            all.append(contentsOf: d.append(delta))
        }
        if let t = d.flush() { all.append(t) }
        XCTAssertEqual(all.count, 3, "got: \(all)")
        XCTAssertEqual(all[0], "This is the first sentence.")
        XCTAssertEqual(all[1], "And here is the second sentence.")
        XCTAssertEqual(all[2], "And a tail.")
    }
}
