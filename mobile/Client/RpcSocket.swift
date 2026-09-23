import Foundation
import ZeronGenerated
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum RpcError: Error, Equatable {
    case closed
    case rejected(String)
    case unauthorized
}

/// Anything that answers Zeron RPC methods with JSON. Normally an `RpcSocket`.
public protocol Transport: Actor {
    func call(_ method: String, _ params: Data) async throws -> Data
    func stream(_ method: String, _ params: Data) -> AsyncThrowingStream<Data, Error>
    func close()
    /// Resolves when the transport dies for any reason.
    func closed() async
}

extension Transport {
    public func call<P, R>(_ rpc: UnaryRpc<P, R>, _ params: P) async throws -> R {
        let data = try await call(rpc.method, JSONEncoder.zeron.encode(params))
        return try JSONDecoder.zeron.decode(R.self, from: data)
    }

    public func stream<P, I>(_ rpc: StreamRpc<P, I>, _ params: P) -> AsyncThrowingStream<I, Error> {
        let (stream, continuation) = AsyncThrowingStream<I, Error>.makeStream()
        let task = Task {
            do {
                let encoded = try JSONEncoder.zeron.encode(params)
                for try await data in await self.stream(rpc.method, encoded) {
                    continuation.yield(try JSONDecoder.zeron.decode(I.self, from: data))
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }
}

/// One WebSocket carrying Zeron's ndjson RPC envelopes.
///
/// Frames out: `{id, method, params}` or `{id, cancel: true}`.
/// Frames in: `{id, ok}` for unary replies, `{id, item}`... `{id, done}` for streams, `{id, err}` on failure.
public actor RpcSocket: Transport {
    private let task: URLSessionWebSocketTask
    private var nextId: UInt64 = 1
    private var unary: [UInt64: CheckedContinuation<Data, Error>] = [:]
    private var streams: [UInt64: Subscriber] = [:]

    private struct Subscriber {
        let item: (Data) -> Void
        let finish: (Error?) -> Void
    }
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var isClosed = false

    public init(endpoint: Endpoint) {
        var request = URLRequest(url: endpoint.url)
        request.setValue("Bearer \(endpoint.token)", forHTTPHeaderField: "Authorization")
        task = URLSession.shared.webSocketTask(with: request)
        task.resume()
        Task { await receiveLoop() }
    }

    public func closed() async {
        if isClosed { return }
        await withCheckedContinuation { closeWaiters.append($0) }
    }

    public func close() {
        task.cancel(with: .goingAway, reason: nil)
        fail(RpcError.closed)
    }

    public func call(_ method: String, _ params: Data) async throws -> Data {
        let id = try await send(method: method, params: params)
        return try await withCheckedThrowingContinuation { unary[id] = $0 }
    }

    public func stream(_ method: String, _ params: Data) -> AsyncThrowingStream<Data, Error> {
        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        Task {
            do {
                let id = try await send(method: method, params: params)
                subscribe(id, Subscriber(
                    item: { continuation.yield($0) },
                    finish: { continuation.finish(throwing: $0) }
                ))
                continuation.onTermination = { _ in Task { await self.cancel(id) } }
            } catch {
                continuation.finish(throwing: error)
            }
        }
        return stream
    }

    // MARK: - Wire

    private func send(method: String, params: Data) async throws -> UInt64 {
        if isClosed { throw RpcError.closed }
        let id = nextId
        nextId += 1
        var frame: [String: Any] = ["id": id, "method": method]
        if let object = try JSONSerialization.jsonObject(with: params) as? [String: Any], !object.isEmpty {
            frame["params"] = object
        }
        try await write(frame)
        return id
    }

    private func subscribe(_ id: UInt64, _ subscriber: Subscriber) {
        if isClosed {
            subscriber.finish(RpcError.closed)
        } else {
            streams[id] = subscriber
        }
    }

    private func cancel(_ id: UInt64) async {
        guard streams.removeValue(forKey: id) != nil, !isClosed else { return }
        try? await write(["id": id, "cancel": true])
    }

    private func write(_ frame: [String: Any]) async throws {
        let data = try JSONSerialization.data(withJSONObject: frame)
        do {
            try await task.send(.string(String(decoding: data, as: UTF8.self)))
        } catch {
            fail(RpcError.closed)
            throw RpcError.closed
        }
    }

    private func receiveLoop() async {
        while !isClosed {
            do {
                switch try await task.receive() {
                case .string(let text): dispatch(Data(text.utf8))
                case .data(let data): dispatch(data)
                @unknown default: break
                }
            } catch {
                fail(closeError())
            }
        }
    }

    private func closeError() -> RpcError {
        if let response = task.response as? HTTPURLResponse, response.statusCode == 401 || response.statusCode == 403 {
            return .unauthorized
        }
        return .closed
    }

    private func dispatch(_ payload: Data) {
        for line in payload.split(separator: UInt8(ascii: "\n")) where !line.isEmpty {
            guard let frame = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = (frame["id"] as? UInt64) ?? (frame["id"] as? Int).map(UInt64.init) else { continue }
            if let err = frame["err"] as? String {
                unary.removeValue(forKey: id)?.resume(throwing: RpcError.rejected(err))
                streams.removeValue(forKey: id)?.finish(RpcError.rejected(err))
            } else if let ok = frame["ok"] {
                unary.removeValue(forKey: id)?.resume(returning: json(ok))
            } else if let item = frame["item"] {
                streams[id]?.item(json(item))
            } else if frame["done"] as? Bool == true {
                streams.removeValue(forKey: id)?.finish(nil)
            }
        }
    }

    private func json(_ value: Any) -> Data {
        (try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed)) ?? Data()
    }

    private func fail(_ error: RpcError) {
        guard !isClosed else { return }
        isClosed = true
        for (_, continuation) in unary { continuation.resume(throwing: error) }
        for (_, subscriber) in streams { subscriber.finish(error) }
        unary.removeAll()
        streams.removeAll()
        for waiter in closeWaiters { waiter.resume() }
        closeWaiters.removeAll()
    }
}
