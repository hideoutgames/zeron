import Foundation
import Observation
import SkipFuse
import ZeronGenerated

/// One chat's message list, kept current by applying `WatchDocMessages` frames.
/// A desync (missing anchor, count mismatch) drops the subscription so the
/// host replies with a fresh reset.
@Observable @MainActor
public final class Transcript {
    public let chatId: String
    public private(set) var entries: [SessionMessageEntry] = []
    public private(set) var loaded = false
    public private(set) var pending: [Pending] = []

    /// A command the host has not confirmed yet.
    public struct Pending: Identifiable, Sendable {
        public let id: String
        public let command: SessionCommandPayload
        public var failed: String?
    }

    @ObservationIgnored private let connection: Connection
    @ObservationIgnored private var subscription: Task<Void, Never>?

    public init(chatId: String, connection: Connection) {
        self.chatId = chatId
        self.connection = connection
    }

    public func start() {
        stop()
        subscription = Task { await follow() }
    }

    public func stop() {
        subscription?.cancel()
        subscription = nil
    }

    // MARK: - Commands

    public func send(_ text: String, attachments: [String] = [], in chat: Chat) {
        let request = RunRequest(
            prompt: Transcript.prompt(text, attachments: attachments),
            harness: chat.config?.harness,
            model: chat.config?.model,
            reasoning: chat.config?.reasoning,
            modelOptions: chat.config?.modelOptions ?? [:],
            cwd: chat.cwd ?? "",
            sandbox: chat.config?.sandbox ?? .workspaceWrite,
            attachments: attachments
        )
        let id = UUID().uuidString.lowercased()
        queue(id, .run(.init(request: request, messageId: id)))
    }

    /// Mirrors upstream `with_attachments`: staged paths ride the prompt as a list.
    static func prompt(_ text: String, attachments: [String]) -> String {
        guard !attachments.isEmpty else { return text }
        let body = text.isEmpty ? "See the attached image(s)." : text
        let refs = attachments.map { "- \($0)" }.joined(separator: "\n")
        return "\(body)\n\nAttached images (local files - open them to view):\n\(refs)"
    }

    public func steer(_ prompt: String) {
        let id = UUID().uuidString.lowercased()
        queue(id, .steer(.init(prompt: prompt, messageId: id)))
    }

    public func interrupt() {
        queue(UUID().uuidString, .interrupt)
    }

    public func respond(_ requestId: String, answers: [UserInputAnswer]) {
        queue(UUID().uuidString, .respondInput(.init(requestId: requestId, answers: answers)))
    }

    public func retry(_ pendingId: String) {
        guard let index = pending.firstIndex(where: { $0.id == pendingId }) else { return }
        pending[index].failed = nil
        Task { await deliver(pending[index]) }
    }

    public func discard(_ pendingId: String) {
        pending.removeAll { $0.id == pendingId }
    }

    private func queue(_ id: String, _ command: SessionCommandPayload) {
        let item = Pending(id: id, command: command)
        pending.append(item)
        Task { await deliver(item) }
    }

    /// Exactly once: a message id doubles as the transcript entry id, so a send
    /// whose reply was lost is resolved by the transcript instead of resent.
    private func deliver(_ item: Pending) async {
        do {
            _ = try await connection.call(Rpc.queueCommand, QueueCommandParams(chatId: chatId, command: item.command))
            settle(item.id)
        } catch RpcError.closed {
            // Reply lost; `follow` decides on the next reset whether it landed.
        } catch {
            if let index = pending.firstIndex(where: { $0.id == item.id }) {
                pending[index].failed = "\(error)"
            }
        }
    }

    private func settle(_ id: String) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        switch pending[index].command {
        case .run, .steer: break
        case .interrupt, .respondInput: pending.remove(at: index)
        }
    }

    private func reconcile(afterReset entries: [SessionMessageEntry]) {
        let landed = Set(entries.map(\.id))
        for item in pending where item.failed == nil {
            if landed.contains(item.id) {
                pending.removeAll { $0.id == item.id }
            } else {
                Task { await deliver(item) }
            }
        }
    }

    // MARK: - Frames

    private func follow() async {
        while !Task.isCancelled {
            for await frame in connection.watch(Rpc.watchDocMessages, ChatParams(chatId: chatId)) {
                if !apply(frame) { break }
            }
        }
    }

    /// Returns false on desync, which restarts the subscription.
    func apply(_ frame: TranscriptFrame) -> Bool {
        switch frame {
        case .reset(let reset):
            entries = reset.reset
            loaded = true
            reconcile(afterReset: entries)
            return true
        case .delta(let delta):
            var next = entries
            guard Transcript.apply(delta, to: &next) else {
                entries = []
                loaded = false
                return false
            }
            entries = next
            pending.removeAll { item in next.contains { $0.id == item.id } }
            return true
        }
    }

    nonisolated static func apply(_ delta: TranscriptFrame.Delta, to entries: inout [SessionMessageEntry]) -> Bool {
        let gone = Set(delta.remove)
        entries.removeAll { gone.contains($0.id) }
        for upsert in delta.upsert {
            entries.removeAll { $0.id == upsert.entry.id }
            let at: Int
            if let anchor = upsert.after {
                guard let index = entries.firstIndex(where: { $0.id == anchor }) else { return false }
                at = index + 1
            } else {
                at = 0
            }
            entries.insert(upsert.entry, at: at)
        }
        for append in delta.append {
            guard let entry = entries.firstIndex(where: { $0.id == append.entry }),
                  let part = entries[entry].parts.firstIndex(where: { $0.id == append.part })
            else { return false }
            switch entries[entry].parts[part] {
            case .text(var text):
                text.text += append.text
                guard text.text.utf8.count == append.len else { return false }
                entries[entry].parts[part] = .text(text)
            case .reasoning(var reasoning):
                reasoning.text += append.text
                guard reasoning.text.utf8.count == append.len else { return false }
                entries[entry].parts[part] = .reasoning(reasoning)
            default:
                return false
            }
        }
        return entries.count == delta.count
    }
}

extension MessagePart {
    public var id: String {
        switch self {
        case .text(let part): part.id
        case .image(let part): part.id
        case .reasoning(let part): part.id
        case .tool(let part): part.id
        case .input(let part): part.id
        case .error(let part): part.id
        case .unrecognized(let kind): kind
        }
    }
}
