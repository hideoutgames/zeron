import Foundation
import Observation
import SkipFuse
import ZeronGenerated

/// The authenticated link to one Zeron host. Reconnects with backoff and lets
/// callers wait for a live socket instead of failing while offline.
@Observable @MainActor
public final class Connection {
    public enum Status: Equatable, Sendable {
        case disconnected
        case connecting
        case connected
        case unauthorized
    }

    public private(set) var status: Status = .disconnected
    public private(set) var endpoint: Endpoint?
    public private(set) var engine: EngineInfo?

    @ObservationIgnored private var socket: (any Transport)?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var waiters: [CheckedContinuation<any Transport, Never>] = []

    public init() {}

    /// `open` makes each attempt's transport; the default speaks to a real host.
    public func connect(_ endpoint: Endpoint, open: @escaping @Sendable (Endpoint) -> any Transport = { RpcSocket(endpoint: $0) }) {
        disconnect()
        self.endpoint = endpoint
        loop = Task { await run(endpoint, open) }
    }

    public func disconnect() {
        loop?.cancel()
        loop = nil
        if let socket {
            Task { await socket.close() }
        }
        socket = nil
        engine = nil
        status = .disconnected
    }

    public func call<P, R>(_ rpc: UnaryRpc<P, R>, _ params: P) async throws -> R {
        try await live().call(rpc, params)
    }

    /// A subscription that survives reconnects: each new socket re-issues the request.
    public func watch<P, I>(_ rpc: StreamRpc<P, I>, _ params: P) -> AsyncStream<I> {
        let (stream, continuation) = AsyncStream<I>.makeStream()
        let task = Task {
            while !Task.isCancelled {
                let socket = await live()
                do {
                    for try await item in await socket.stream(rpc, params) {
                        continuation.yield(item)
                    }
                } catch {}
                await socket.closed()
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    // MARK: - Lifecycle

    private func live() async -> any Transport {
        if let socket { return socket }
        return await withCheckedContinuation { waiters.append($0) }
    }

    private func run(_ endpoint: Endpoint, _ open: @Sendable (Endpoint) -> any Transport) async {
        var delay: Double = 1
        while !Task.isCancelled {
            status = .connecting
            let candidate = open(endpoint)
            do {
                engine = try await candidate.call(Rpc.engineInfo, NoParams())
            } catch RpcError.unauthorized {
                status = .unauthorized
                return
            } catch {
                status = .disconnected
                try? await Task.sleep(for: .seconds(delay))
                delay = min(delay * 2, 30)
                continue
            }
            delay = 1
            socket = candidate
            status = .connected
            waiters.forEach { $0.resume(returning: candidate) }
            waiters.removeAll()
            await candidate.closed()
            socket = nil
            status = .disconnected
        }
    }
}
