import Foundation
import Observation
import SkipFuse
import ZeronGenerated

/// Live mirror of the host's devices, spaces, chats and sessions.
@Observable @MainActor
public final class Workspace {
    public private(set) var devices: [Device] = []
    public private(set) var spaces: [Space] = []
    public private(set) var chats: [Chat] = []
    public private(set) var sessions: [Session] = []
    public private(set) var loaded = false

    @ObservationIgnored private var tasks: [Task<Void, Never>] = []

    public init() {}

    public func start(_ connection: Connection) {
        stop()
        tasks = [
            Task { for await value in connection.watch(Rpc.watchDevices, NoParams()) { devices = value } },
            Task { for await value in connection.watch(Rpc.watchSpaces, NoParams()) { spaces = value } },
            Task { for await value in connection.watch(Rpc.watchChats, NoParams()) { chats = value; loaded = true } },
            Task { for await value in connection.watch(Rpc.watchSessions, NoParams()) { sessions = value } },
        ]
    }

    public func stop() {
        tasks.forEach { $0.cancel() }
        tasks = []
        loaded = false
    }

    public func chats(in space: Space?) -> [Chat] {
        chats
            .filter { !$0.archived && (space == nil || $0.spaceId == space?.id) }
            .sorted { ($0.lastMessageAt ?? $0.createdAt) > ($1.lastMessageAt ?? $1.createdAt) }
    }

    public func session(for chat: Chat) -> Session? {
        sessions.first { $0.chatId == chat.id }
    }

    public func device(for chat: Chat) -> Device? {
        devices.first { $0.id == chat.deviceId }
    }

    public func space(for chat: Chat) -> Space? {
        spaces.first { $0.id == chat.spaceId }
    }

    public func indicator(for chat: Chat) -> ChatIndicator {
        let unseen = chat.lastMessageAt.map { at in chat.lastSeenAt.map { $0 < at } ?? true } ?? false
        switch session(for: chat)?.status {
        case .working: return .working
        case .awaitingInput: return .awaitingInput
        case .errored where unseen: return .errored
        default: return unseen ? .completed : .idle
        }
    }
}

/// Mirrors upstream `chat_indicator`, which is computed rather than serialized.
public enum ChatIndicator: Sendable {
    case working, awaitingInput, errored, completed, idle
}
