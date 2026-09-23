import SwiftUI
#if !os(Android)
import UIKit
#endif
import ZeronClient
import ZeronGenerated

struct MessageView: View {
    let entry: SessionMessageEntry
    let chat: Chat
    let transcript: Transcript

    var body: some View {
        if entry.role == .user {
            UserBubble(text: entry.parts.compactMap(\.plainText).joined(separator: "\n"))
        } else {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(entry.parts, id: \.id) { part in
                    PartView(part: part, chat: chat, transcript: transcript)
                }
                if entry.status == .aborted {
                    Label("Stopped", systemImage: "stop.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct UserBubble: View {
    let text: String

    var body: some View {
        HStack {
            Spacer(minLength: 40)
            Text(text)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 18))
                .selectable()
        }
    }
}

struct PartView: View {
    let part: MessagePart
    let chat: Chat
    let transcript: Transcript
    @State var showReasoning = false

    var body: some View {
        switch part {
        case .text(let text):
            MarkdownText(text: text.text)
        case .reasoning(let reasoning):
            DisclosureGroup(isExpanded: $showReasoning) {
                Text(reasoning.text)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .selectable()
            } label: {
                Label("Thinking", systemImage: "brain")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        case .tool(let tool):
            ToolRow(tool: tool)
        case .input(let input):
            QuestionCard(input: input, transcript: transcript)
        case .image(let image):
            AttachmentImage(path: image.path, deviceId: chat.deviceId)
        case .error(let error):
            Label(error.message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.red)
        case .unrecognized(let kind):
            Label(kind, systemImage: "questionmark.square.dashed")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }
}

struct MarkdownText: View {
    let text: String

    var body: some View {
        #if os(Android)
        Text(text).selectable()
        #else
        Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
            .selectable()
        #endif
    }
}

/// One line per tool call: glyph, subject, optional diff stat.
struct ToolRow: View {
    let tool: MessagePart.Tool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: tool.isError ? "xmark.circle" : tool.resolved ? symbol : "circle.dotted")
                .foregroundStyle(tool.isError ? .red : .secondary)
                .frame(width: 16)
            Text(subject)
                .font(.footnote.monospaced())
                .lineLimit(1)
                .truncatedMiddle()
            Spacer()
            if let stats = tool.diffStats, !stats.isEmpty {
                DiffStat(additions: stats.map(\.additions).reduce(0, +), deletions: stats.map(\.deletions).reduce(0, +))
            }
        }
        .foregroundStyle(.secondary)
        .combinedAccessibility()
    }

    private var symbol: String {
        switch tool.call {
        case .exec: "terminal"
        case .readFile: "doc.text"
        case .writeFile, .editFile, .applyPatch: "pencil"
        case .search, .glob: "magnifyingglass"
        case .webFetch, .webSearch: "globe"
        case .todo: "checklist"
        case .mcp: "puzzlepiece.extension"
        case .unknown, .unrecognized: "wrench"
        }
    }

    private var subject: String {
        switch tool.call {
        case .exec(let call): call.command
        case .readFile(let call): call.path
        case .writeFile(let call): call.path
        case .editFile(let call): call.path
        case .applyPatch(let call): call.path ?? "patch"
        case .search(let call): call.pattern
        case .glob(let call): call.pattern
        case .webFetch(let call): call.url
        case .webSearch(let call): call.query
        case .todo(let call): "\(call.items.filter(\.done).count)/\(call.items.count)"
        case .mcp(let call): "\(call.server).\(call.tool)"
        case .unknown(let call): call.name
        case .unrecognized(let kind): kind
        }
    }
}

struct DiffStat: View {
    let additions: Int
    let deletions: Int

    var body: some View {
        HStack(spacing: 4) {
            Text("+\(additions)").foregroundStyle(.green)
            Text("-\(deletions)").foregroundStyle(.red)
        }
        .font(.caption.monospaced())
    }
}

/// A transcript image fetched from the device that stores it.
struct AttachmentImage: View {
    let path: String
    let deviceId: String

    @Environment(AppModel.self) var app
    @State var image: Image?
    @State var failed = false

    var body: some View {
        Group {
            if let image {
                image.resizable().scaledToFit()
            } else if failed {
                Image(systemName: "photo.badge.exclamationmark").foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: 240, maxHeight: 240)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .task {
            do {
                let data = try await Attachments.download(path, from: deviceId, via: app.connection)
                if let decoded = UIImage(data: data) {
                    image = Image(uiImage: decoded)
                } else {
                    failed = true
                }
            } catch {
                failed = true
            }
        }
    }
}

extension MessagePart {
    var plainText: String? {
        if case .text(let text) = self { return text.text }
        return nil
    }
}
