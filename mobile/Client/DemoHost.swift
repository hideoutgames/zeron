import Foundation
import ZeronGenerated

/// A host that lives inside the app. Serves sample devices, spaces and chats,
/// streams a reply word by word, asks a question and answers every command,
/// so each screen can be previewed without a running Zeron.
public actor DemoHost: Transport {
    private var transcripts = Demo.transcripts
    private var sessions = Demo.sessions
    private var transcriptWatchers: [String: [AsyncThrowingStream<Data, Error>.Continuation]] = [:]
    private var sessionWatchers: [AsyncThrowingStream<Data, Error>.Continuation] = []
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []
    private var liveStarted = false

    public init() {}

    public func call(_ method: String, _ params: Data) async throws -> Data {
        switch method {
        case Rpc.engineInfo.method:
            return try encode(Demo.engine)
        case Rpc.queueCommand.method:
            let request = try JSONDecoder.zeron.decode(QueueCommandParams.self, from: params)
            handle(request.command, in: request.chatId)
            return try encode(QueuedCommand(commandId: UUID().uuidString))
        case Rpc.getCheckoutDiff.method:
            return try encode(Demo.diff)
        case Rpc.uploadChunk.method:
            return try encode(JSONValue.null)
        case Rpc.uploadCommit.method:
            return try encode(UploadCommitted(path: Demo.imagePath))
        case Rpc.readAttachmentChunk.method:
            return try encode(AttachmentChunk(name: "preview.png", mimeType: "image/png", data: Demo.png, nextOffset: 0, done: true))
        default:
            throw RpcError.rejected("unsupported in demo: \(method)")
        }
    }

    public func stream(_ method: String, _ params: Data) -> AsyncThrowingStream<Data, Error> {
        switch method {
        case Rpc.watchDevices.method: return fixed(Demo.devices)
        case Rpc.watchSpaces.method: return fixed(Demo.spaces)
        case Rpc.watchChats.method: return fixed(Demo.chats)
        case Rpc.watchSessions.method:
            return AsyncThrowingStream { continuation in
                Task { await self.watchSessions(continuation) }
            }
        case Rpc.watchDocMessages.method:
            let chatId = (try? JSONDecoder.zeron.decode(ChatParams.self, from: params).chatId) ?? ""
            return AsyncThrowingStream { continuation in
                Task { await self.watchTranscript(chatId, continuation) }
            }
        default:
            return AsyncThrowingStream { $0.finish(throwing: RpcError.rejected("unsupported in demo: \(method)")) }
        }
    }

    public func close() {
        closeWaiters.forEach { $0.resume() }
        closeWaiters.removeAll()
    }

    public func closed() async {
        await withCheckedContinuation { closeWaiters.append($0) }
    }

    // MARK: - Subscriptions

    private func watchSessions(_ continuation: AsyncThrowingStream<Data, Error>.Continuation) {
        continuation.yield(with: Result { try encode(sessions) })
        sessionWatchers.append(continuation)
    }

    private func watchTranscript(_ chatId: String, _ continuation: AsyncThrowingStream<Data, Error>.Continuation) {
        continuation.yield(with: Result { try encode(TranscriptFrame.reset(.init(reset: transcripts[chatId] ?? []))) })
        transcriptWatchers[chatId, default: []].append(continuation)
        if chatId == Demo.liveChat, !liveStarted {
            liveStarted = true
            Task { await finishReply(Demo.liveReply, in: chatId, words: Demo.liveWords) }
        }
    }

    private nonisolated func fixed<T: Encodable>(_ value: T) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { $0.yield(with: Result { try encode(value) }) }
    }

    private nonisolated func encode<T: Encodable>(_ value: T) throws -> Data {
        try JSONEncoder.zeron.encode(value)
    }

    // MARK: - Commands

    private func handle(_ command: SessionCommandPayload, in chatId: String) {
        switch command {
        case .run(let run):
            upsert(Demo.userEntry(run.messageId, run.request.prompt), in: chatId)
            reply(to: run.request.prompt, in: chatId)
        case .steer(let steer):
            upsert(Demo.userEntry(steer.messageId ?? UUID().uuidString, steer.prompt), in: chatId)
            reply(to: steer.prompt, in: chatId)
        case .interrupt:
            for entry in transcripts[chatId, default: []] where entry.status == .streaming {
                var stopped = entry
                stopped.status = .aborted
                upsert(stopped, in: chatId)
            }
            setStatus(.idle, in: chatId)
        case .respondInput(let response):
            for entry in transcripts[chatId, default: []] {
                for case .input(var input) in entry.parts where input.requestId == response.requestId {
                    input.resolved = true
                    var answered = entry
                    answered.parts = entry.parts.map { $0.id == input.id ? .input(input) : $0 }
                    upsert(answered, in: chatId)
                }
            }
            reply(to: response.answers.flatMap(\.labels).joined(separator: ", "), in: chatId)
        }
    }

    private func reply(to prompt: String, in chatId: String) {
        let id = UUID().uuidString.lowercased()
        upsert(Demo.assistantEntry(id, reasoning: "The user said \"\(prompt)\". Keeping the answer short."), in: chatId)
        setStatus(.working, in: chatId)
        Task { await finishReply(id, in: chatId, words: Demo.echoWords(prompt)) }
    }

    private func finishReply(_ entryId: String, in chatId: String, words: [String]) async {
        for word in words {
            try? await Task.sleep(for: .milliseconds(80))
            guard let entry = transcripts[chatId]?.first(where: { $0.id == entryId }), entry.status == .streaming else { return }
            append(word, to: entry, in: chatId)
        }
        if var done = transcripts[chatId]?.first(where: { $0.id == entryId }), done.status == .streaming {
            done.status = .complete
            for index in done.parts.indices {
                if case .tool(var tool) = done.parts[index] {
                    tool.resolved = true
                    done.parts[index] = .tool(tool)
                }
            }
            upsert(done, in: chatId)
        }
        setStatus(.idle, in: chatId)
    }

    // MARK: - Transcript mutations, published as deltas

    private func upsert(_ entry: SessionMessageEntry, in chatId: String) {
        var entries = transcripts[chatId, default: []]
        let after: String?
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
            after = index > 0 ? entries[index - 1].id : nil
        } else {
            after = entries.last?.id
            entries.append(entry)
        }
        transcripts[chatId] = entries
        publish(.init(upsert: [.init(after: after, entry: entry)], count: entries.count), in: chatId)
    }

    private func append(_ word: String, to entry: SessionMessageEntry, in chatId: String) {
        guard case .text(var text) = entry.parts.last, var entries = transcripts[chatId],
              let index = entries.firstIndex(where: { $0.id == entry.id }) else { return }
        text.text += word
        entries[index].parts[entries[index].parts.count - 1] = .text(text)
        transcripts[chatId] = entries
        publish(.init(append: [.init(entry: entry.id, part: text.id, text: word, len: text.text.utf8.count)], count: entries.count), in: chatId)
    }

    private func publish(_ delta: TranscriptFrame.Delta, in chatId: String) {
        for watcher in transcriptWatchers[chatId, default: []] {
            watcher.yield(with: Result { try encode(TranscriptFrame.delta(delta)) })
        }
    }

    private func setStatus(_ status: SessionStatus, in chatId: String) {
        guard let index = sessions.firstIndex(where: { $0.chatId == chatId }) else { return }
        sessions[index].status = status
        sessions[index].updatedAt = Date()
        for watcher in sessionWatchers {
            watcher.yield(with: Result { try encode(sessions) })
        }
    }
}

// MARK: - Sample data

enum Demo {
    static let mac = "demo-mac"
    static let box = "demo-box"
    static let liveChat = "demo-chat-auth"
    static let liveReply = "demo-reply-auth"
    static let imagePath = "/tmp/zeron-demo/preview.png"

    static let engine = EngineInfo(deviceId: mac, workspaceScope: .local, capabilities: [])

    static let devices = [
        Device(id: mac, name: "MacBook Pro", platform: "macos", lastSeenAt: Date(), version: "0.4.2"),
        Device(id: box, name: "build-box", platform: "linux", lastSeenAt: Date(timeIntervalSinceNow: -900), version: "0.4.2"),
    ]

    static let spaces = [
        Space(id: "demo-space-zeron", deviceId: mac, path: "~/code/zeron", name: "zeron", gitDetected: true, createdAt: ago(days: 30)),
        Space(id: "demo-space-site", deviceId: box, path: "~/code/website", name: "website", gitDetected: true, createdAt: ago(days: 12)),
    ]

    static let chats = [
        chat(liveChat, "Fix flaky auth test", space: 0, branch: "fix/auth-retry", preview: "Running the suite again", minutes: 1, seen: true),
        chat("demo-chat-dark", "Add dark mode", space: 0, branch: "feat/dark-mode", preview: "Which accent should I use?", minutes: 25, seen: true),
        chat("demo-chat-ci", "Migrate CI to Bun", space: 1, branch: "chore/bun-ci", preview: "bun install failed", minutes: 180, seen: false),
        chat("demo-chat-router", "Refactor router", space: 1, branch: "main", preview: "Done. Two files changed.", minutes: 1440, seen: true),
    ]

    static let sessions = [
        Session(chatId: liveChat, deviceId: mac, status: .working, startedAt: Date(), updatedAt: Date()),
        Session(chatId: "demo-chat-dark", deviceId: mac, status: .awaitingInput, updatedAt: ago(minutes: 25)),
        Session(chatId: "demo-chat-ci", deviceId: box, status: .errored, updatedAt: ago(minutes: 180)),
        Session(chatId: "demo-chat-router", deviceId: box, status: .idle, updatedAt: ago(minutes: 1440)),
    ]

    static let transcripts: [String: [SessionMessageEntry]] = [
        liveChat: [
            userEntry("demo-u1", "The login test fails every third run. Find out why."),
            entry("demo-a1", .assistant, [
                .reasoning(.init(id: "r1", text: "Flaky on retry suggests shared state. Check the token cache first.")),
                .tool(.init(id: "t1", call: .search(.init(pattern: "tokenCache", path: "tests/")), resolved: true)),
                .tool(.init(id: "t2", call: .readFile(.init(path: "tests/auth/login.test.ts")), resolved: true)),
                .text(.init(id: "x1", text: "The cache is module scoped, so a passing run leaves a token behind for the next one.")),
            ], status: .complete),
            entry(liveReply, .assistant, [
                .tool(.init(id: "t3", call: .editFile(.init(path: "tests/auth/login.test.ts")), resolved: true, diffStats: [.init(path: "tests/auth/login.test.ts", additions: 4, deletions: 1)])),
                .tool(.init(id: "t4", call: .exec(.init(command: "bun test tests/auth")))),
                .text(.init(id: "x2", text: "")),
            ], status: .streaming),
        ],
        "demo-chat-dark": [
            userEntry("demo-u2", "Add a dark mode toggle to settings."),
            entry("demo-a2", .assistant, [
                .tool(.init(id: "t5", call: .glob(.init(pattern: "**/Settings*.swift")), resolved: true)),
                .text(.init(id: "x3", text: "Settings already reads the system scheme. A toggle needs an accent choice too.")),
                .input(.init(id: "q1", requestId: "demo-req-1", questions: [
                    .init(id: "accent", header: "Accent", question: "Which accent should dark mode use?", options: ["Indigo", "Teal", "Match system"]),
                ])),
            ], status: .complete),
        ],
        "demo-chat-ci": [
            userEntry("demo-u3", "Switch the CI workflow from npm to bun."),
            entry("demo-a3", .assistant, [
                .tool(.init(id: "t6", call: .writeFile(.init(path: ".github/workflows/ci.yml")), resolved: true, diffStats: [.init(path: ".github/workflows/ci.yml", additions: 12, deletions: 18)])),
                .tool(.init(id: "t7", call: .exec(.init(command: "bun install --frozen-lockfile")), isError: true, resolved: true)),
                .error(.init(id: "e1", message: "bun install failed: lockfile out of date")),
            ], status: .complete),
        ],
        "demo-chat-router": [
            userEntry("demo-u4", "Split the router into one file per route group."),
            entry("demo-a4", .assistant, [
                .reasoning(.init(id: "r2", text: "Two groups: marketing and app. Keep the index as a barrel.")),
                .tool(.init(id: "t8", call: .applyPatch(.init(path: "src/router")), resolved: true, diffStats: [
                    .init(path: "src/router/index.ts", additions: 6, deletions: 41),
                    .init(path: "src/router/app.ts", additions: 28, deletions: 0),
                ])),
                .tool(.init(id: "t9", call: .webFetch(.init(url: "https://reactrouter.com/start/data/routing")), resolved: true)),
                .image(.init(id: "i1", path: imagePath, name: "preview.png", mimeType: "image/png")),
                .text(.init(id: "x4", text: "Done. Two files changed, **preview attached**.")),
            ], status: .complete),
        ],
    ]

    static let diff = CheckoutDiff(
        checkoutId: "demo-checkout", deviceId: box, cwd: "~/code/website",
        patch: """
        diff --git a/src/router/index.ts b/src/router/index.ts
        --- a/src/router/index.ts
        +++ b/src/router/index.ts
        @@ -1,6 +1,4 @@
        -import { Home } from "./pages/Home";
        -import { Pricing } from "./pages/Pricing";
        -import { Dashboard } from "./pages/Dashboard";
        +import { marketing } from "./marketing";
        +import { app } from "./app";

        -export const routes = [Home, Pricing, Dashboard];
        +export const routes = [...marketing, ...app];
        diff --git a/src/router/app.ts b/src/router/app.ts
        new file mode 100644
        --- /dev/null
        +++ b/src/router/app.ts
        @@ -0,0 +1,3 @@
        +import { Dashboard } from "../pages/Dashboard";
        +
        +export const app = [Dashboard];
        """,
        files: [
            .init(path: "src/router/index.ts", status: "modified", additions: 3, deletions: 4, binary: false),
            .init(path: "src/router/app.ts", status: "added", additions: 3, deletions: 0, binary: false),
        ],
        additions: 6, deletions: 4, truncated: false, checksum: "demo", updatedAt: Date()
    )

    static let liveWords = words("All green. The cache is now reset in `beforeEach`, so each run starts signed out.")

    static func echoWords(_ prompt: String) -> [String] {
        words("Noted: \(prompt.prefix(60)). In the demo nothing runs, but the transcript, session state and pending bar behave like the real thing.")
    }

    static let png = "iVBORw0KGgoAAAANSUhEUgAAAEAAAAAoCAIAAADBrGu+AAAA4klEQVR42u3P0WYCAACG0R4sM8lkkiSZJEmSJEmSJEmSfJIkSZIkSZIkSTJJkmQmSXqYeoXu/4vzAMdg5PHB/ZObiauZyxf/Fv6+OVs52TjaOTjYO9m52P7w62bjYe1l5WPpZxFgHmQWYhpmEmEcZRRjGGeQoJ+kl6KbppOhnaWVo5mnUaBepFaiWqYCL+UqpRrFOoUG+Sa5Ftk2mQ7pLqkeyT6JAfEhsRHRMZEJ4SmhGcE5gQX+Jb4VXoMCCiiggAIKKKCAAgoooIACCiiggAIKKKCAAgoooIACCiiggALvBJ5pi2jx9iHrggAAAABJRU5ErkJggg=="

    // MARK: Builders

    static func userEntry(_ id: String, _ text: String) -> SessionMessageEntry {
        entry(id, .user, [.text(.init(id: id + "-text", text: text))], status: .complete)
    }

    static func assistantEntry(_ id: String, reasoning: String) -> SessionMessageEntry {
        entry(id, .assistant, [.reasoning(.init(id: id + "-think", text: reasoning)), .text(.init(id: id + "-text", text: ""))], status: .streaming)
    }

    private static func entry(_ id: String, _ role: MessageRole, _ parts: [MessagePart], status: MessageStatus) -> SessionMessageEntry {
        SessionMessageEntry(id: id, role: role, parts: parts, createdAt: Int(Date().timeIntervalSince1970 * 1000), deviceId: mac, status: status)
    }

    private static func chat(_ id: String, _ title: String, space: Int, branch: String, preview: String, minutes: Double, seen: Bool) -> Chat {
        Chat(
            id: id, deviceId: spaces[space].deviceId, title: title, archived: false, cwd: spaces[space].path, branch: branch,
            checkoutId: "demo-checkout", config: .init(harness: .codex, model: "gpt-5", modelOptions: [:], sandbox: .workspaceWrite),
            lastMessagePreview: preview, lastMessageAt: ago(minutes: minutes), createdAt: ago(minutes: minutes + 30),
            spaceId: spaces[space].id, lastSeenAt: seen ? Date() : nil
        )
    }

    private static func words(_ text: String) -> [String] {
        text.split(separator: " ", omittingEmptySubsequences: false).enumerated().map { $0.offset == 0 ? String($0.element) : " " + $0.element }
    }

    private static func ago(minutes: Double = 0, days: Double = 0) -> Date {
        Date(timeIntervalSinceNow: -(minutes * 60 + days * 86_400))
    }
}
