import Foundation
import XCTest
import ZeronGenerated
@testable import ZeronClient

final class TranscriptTests: XCTestCase {
    func testDeltaAppliesUpsertAndAppend() throws {
        guard case .reset(let reset) = try fixture(TranscriptFrame.self, "frame-reset"),
              case .delta(let delta) = try fixture(TranscriptFrame.self, "frame-delta")
        else { return XCTFail("fixture shape") }

        var entries = reset.reset
        XCTAssertTrue(Transcript.apply(delta, to: &entries))
        XCTAssertEqual(entries.map(\.id), ["msg-0", "msg-1"])
        guard case .text(let text) = entries[1].parts[0] else { return XCTFail("part") }
        XCTAssertEqual(text.text, "Hello")
    }

    func testDesyncIsRejected() throws {
        guard case .reset(let reset) = try fixture(TranscriptFrame.self, "frame-reset"),
              case .delta(let delta) = try fixture(TranscriptFrame.self, "frame-delta")
        else { return XCTFail("fixture shape") }

        var empty: [SessionMessageEntry] = []
        XCTAssertFalse(Transcript.apply(delta, to: &empty), "missing anchor")

        var wrongLength = delta
        wrongLength.append[0].len = 99
        var entries = reset.reset
        XCTAssertFalse(Transcript.apply(wrongLength, to: &entries), "length tripwire")
    }
}
