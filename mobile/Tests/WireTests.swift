import Foundation
import XCTest
import ZeronGenerated

/// Fixtures shared with `crates/doc/tests/mobile_fixtures.rs`: Rust proves the
/// bytes are what the host emits, this proves the client reads and re-emits them.
final class WireTests: XCTestCase {
    func testFixturesRoundTrip() throws {
        try roundTrip(Chat.self, "chat")
        try roundTrip(Session.self, "session")
        try roundTrip(SessionMessageEntry.self, "entry")
        try roundTrip(TranscriptFrame.self, "frame-reset")
        try roundTrip(TranscriptFrame.self, "frame-delta")
        for name in ["run", "steer", "interrupt", "respond"] {
            try roundTrip(SessionCommandPayload.self, "command-\(name)")
        }
    }

    func testEveryPartKindDecodesTyped() throws {
        let entry = try fixture(SessionMessageEntry.self, "entry")
        let kinds = entry.parts.map { part -> String in
            switch part {
            case .text: "text"
            case .reasoning: "reasoning"
            case .tool: "tool"
            case .image: "image"
            case .input: "input"
            case .error: "error"
            case .unrecognized: "?"
            }
        }
        XCTAssertEqual(kinds, ["text", "reasoning", "tool", "image", "input", "error"])
    }

    private func roundTrip<T: Codable & Equatable>(_ type: T.Type, _ name: String) throws {
        let first = try fixture(type, name)
        let again = try JSONDecoder.zeron.decode(type, from: JSONEncoder.zeron.encode(first))
        XCTAssertEqual(first, again, name)
    }
}

func fixture<T: Decodable>(_ type: T.Type, _ name: String) throws -> T {
    let url = try XCTUnwrap(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try JSONDecoder.zeron.decode(type, from: Data(contentsOf: url))
}
