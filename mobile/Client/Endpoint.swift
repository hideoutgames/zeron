import Foundation
import ZeronPlatform

/// Where the host's mobile listener lives and the bearer token that unlocks it.
public struct Endpoint: Hashable, Sendable {
    public var url: URL
    public var token: String

    public init(url: URL, token: String) {
        self.url = url
        self.token = token
    }

    /// Accepts `host:port`, `ws://…` or `wss://…`; bare hosts default to `ws://`.
    public init?(address: String, token: String) {
        let trimmed = address.trimmingCharacters(in: .whitespaces)
        let withScheme = trimmed.contains("://") ? trimmed : "ws://" + trimmed
        guard let url = URL(string: withScheme), url.host != nil, !token.isEmpty else { return nil }
        self.init(url: url, token: token)
    }

    private static let urlKey = "zeron.endpoint.url"
    private static let tokenKey = "zeron.endpoint.token"

    public static func load() -> Endpoint? {
        guard let raw = Secrets.read(urlKey), let url = URL(string: raw), let token = Secrets.read(tokenKey) else { return nil }
        return Endpoint(url: url, token: token)
    }

    public func save() {
        Secrets.write(url.absoluteString, for: Self.urlKey)
        Secrets.write(token, for: Self.tokenKey)
    }

    public static func forget() {
        Secrets.write(nil, for: urlKey)
        Secrets.write(nil, for: tokenKey)
    }
}
