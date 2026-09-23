import Foundation

/// A unary RPC method with typed params and reply.
public struct UnaryRpc<Params: Encodable & Sendable, Reply: Decodable & Sendable>: Sendable {
    public let method: String
    public init(_ method: String) { self.method = method }
}

/// A streaming RPC method: one `item` frame per element until `done`.
public struct StreamRpc<Params: Encodable & Sendable, Item: Decodable & Sendable>: Sendable {
    public let method: String
    public init(_ method: String) { self.method = method }
}

/// Params for methods that take none.
public struct NoParams: Codable, Hashable, Sendable {
    public init() {}
}

/// Arbitrary JSON, for fields typed `serde_json::Value` upstream.
public indirect enum JSONValue: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let single = try decoder.singleValueContainer()
        if single.decodeNil() {
            self = .null
        } else if let value = try? single.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? single.decode(Double.self) {
            self = .number(value)
        } else if let value = try? single.decode(String.self) {
            self = .string(value)
        } else if let value = try? single.decode([JSONValue].self) {
            self = .array(value)
        } else {
            self = .object(try single.decode([String: JSONValue].self))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var single = encoder.singleValueContainer()
        switch self {
        case .null: try single.encodeNil()
        case .bool(let value): try single.encode(value)
        case .number(let value): try single.encode(value)
        case .string(let value): try single.encode(value)
        case .array(let value): try single.encode(value)
        case .object(let value): try single.encode(value)
        }
    }
}

/// Coding key for serde's internally tagged enums (`#[serde(tag = "kind")]`).
struct TagKey: CodingKey {
    var stringValue: String
    var intValue: Int? { nil }
    init(_ name: String) { stringValue = name }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { nil }
}

extension JSONDecoder {
    /// Decoder matching serde's wire conventions (RFC 3339 dates with optional fractions).
    public static var zeron: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let text = try decoder.singleValueContainer().decode(String.self)
            guard let date = RFC3339.date(from: text) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "bad date \(text)"))
            }
            return date
        }
        return decoder
    }
}

extension JSONEncoder {
    public static var zeron: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var single = encoder.singleValueContainer()
            try single.encode(RFC3339.string(from: date))
        }
        return encoder
    }
}

enum RFC3339 {
    static func date(from text: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }

    static func string(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }
}
