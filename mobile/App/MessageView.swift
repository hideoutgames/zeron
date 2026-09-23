import SwiftUI
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
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Segment.split(entry.parts), id: \.id) { segment in
                    switch segment {
                    case .tools(let tools):
                        ToolGroup(tools: tools)
                    case .part(let part):
                        PartView(part: part, live: entry.status == .streaming && part.id == entry.parts.last?.id, chat: chat, transcript: transcript)
                    }
                }
                if entry.status == .aborted {
                    Image(glyph: "stop.circle")
                        .font(.caption)
                        .foregroundStyle(Theme.faint)
                        .accessibilityLabel("Stopped")
                }
            }
        }
    }
}

/// Adjacent tool calls collapse into one quiet rail; everything else stands alone.
enum Segment {
    case part(MessagePart)
    case tools([MessagePart.Tool])

    var id: String {
        switch self {
        case .part(let part): part.id
        case .tools(let tools): tools[0].id
        }
    }

    static func split(_ parts: [MessagePart]) -> [Segment] {
        var segments: [Segment] = []
        for part in parts {
            if case .tool(let tool) = part, case .tools(let run)? = segments.last {
                segments[segments.count - 1] = .tools(run + [tool])
            } else if case .tool(let tool) = part {
                segments.append(.tools([tool]))
            } else {
                segments.append(.part(part))
            }
        }
        return segments
    }
}

struct UserBubble: View {
    let text: String

    var body: some View {
        HStack {
            Spacer(minLength: 48)
            Text(text)
                .foregroundStyle(Theme.text)
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(Theme.raised, in: RoundedRectangle(cornerRadius: Theme.bubbleRadius))
                .selectable()
        }
    }
}

struct PartView: View {
    let part: MessagePart
    let live: Bool
    let chat: Chat
    let transcript: Transcript
    @State var showReasoning = false

    var body: some View {
        switch part {
        case .text(let text):
            if live {
                StreamingText(text: text.text)
            } else {
                MarkdownText(text: text.text)
            }
        case .reasoning(let reasoning):
            DisclosureGroup(isExpanded: $showReasoning) {
                Text(reasoning.text)
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
                    .selectable()
            } label: {
                Image(glyph: "brain")
                    .font(.footnote)
                    .foregroundStyle(Theme.faint)
                    .accessibilityLabel("Thinking")
            }
        case .tool(let tool):
            ToolGroup(tools: [tool])
        case .input(let input):
            QuestionCard(input: input, transcript: transcript)
        case .image(let image):
            AttachmentImage(path: image.path, deviceId: chat.deviceId)
        case .error(let error):
            Chip(glyph: "exclamationmark.triangle", tint: Theme.danger, text: error.message)
        case .unrecognized(let kind):
            Chip(glyph: "questionmark.square.dashed", tint: Theme.faint, text: kind)
        }
    }
}

/// A one-line notice in the transcript: glyph on a tinted square, then the message.
struct Chip: View {
    let glyph: String
    let tint: Color
    let text: String

    var body: some View {
        HStack(spacing: 8) {
            Image(glyph: glyph)
                .font(.caption2)
                .foregroundStyle(tint)
                .frame(width: 20, height: 20)
                .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: Theme.controlRadius))
            Text(text)
                .font(.caption)
                .foregroundStyle(Theme.text.opacity(0.8))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(height: 34)
        .panel(tint.opacity(0.05))
        .combinedAccessibility()
    }
}

struct MarkdownText: View {
    let text: String

    var body: some View {
        #if os(Android)
        Text(text).foregroundStyle(Theme.text).selectable()
        #else
        Text((try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(text))
            .foregroundStyle(Theme.text)
            .selectable()
        #endif
    }
}

/// Text still arriving. Settled text keeps its colour; only the newest run fades in,
/// so nothing already read flickers. Android shows the plain text.
struct StreamingText: View {
    let text: String

    @State var settled = ""
    @State var shown = ""
    @State var fade = 1.0

    var body: some View {
        #if os(Android)
        Text(text).foregroundStyle(Theme.text)
        #else
        faded
            .task(id: text) {
                settled = shown
                shown = text
                for step in 1...8 {
                    fade = Double(step) / 8
                    try? await Task.sleep(for: .milliseconds(30))
                }
                settled = text
            }
        #endif
    }

    #if !os(Android)
    private var faded: Text {
        guard text.hasPrefix(settled) else { return Text(text).foregroundColor(Theme.text) }
        return Text(settled).foregroundColor(Theme.text)
            + Text(text.dropFirst(settled.count)).foregroundColor(Theme.text.opacity(0.25 + 0.75 * fade))
    }
    #endif
}

/// Desktop's activity rail: a thin thread of tool calls, each a glyph, its subject and a diff stat.
/// Long runs fold behind a count.
struct ToolGroup: View {
    let tools: [MessagePart.Tool]
    @State var open = false

    private var folded: Bool { tools.count > 3 && !open }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if tools.count > 3 {
                Button { open.toggle() } label: {
                    HStack(spacing: 10) {
                        Image(systemName: open ? "chevron.down" : "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .frame(width: 20)
                        Text("\(tools.count)")
                            .font(.footnote.monospaced())
                        if tools.contains(where: \.isError) {
                            Circle().fill(Theme.danger).frame(width: 6, height: 6)
                        }
                        Spacer()
                    }
                    .foregroundStyle(Theme.muted)
                    .frame(minHeight: 32)
                    .tappable()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Tools")
            }
            if !folded {
                ForEach(tools, id: \.id) { tool in
                    ToolRow(tool: tool, continues: tool.id != tools.last?.id)
                }
            }
        }
    }
}

struct ToolRow: View {
    let tool: MessagePart.Tool
    var continues = false

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(spacing: 4) {
                Image(glyph: tool.isError ? "xmark.circle" : tool.resolved ? symbol : "circle.dotted")
                    .font(.footnote)
                    .foregroundStyle(tool.isError ? Theme.danger : Theme.muted)
                    .frame(width: 20, height: 20)
                Rectangle()
                    .fill(continues ? Theme.borderStrong : .clear)
                    .frame(width: 1)
            }
            .frame(width: 20)
            Text(subject)
                .font(.footnote.monospaced())
                .foregroundStyle(Theme.text.opacity(0.85))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let stats = tool.diffStats, !stats.isEmpty {
                DiffStat(additions: stats.map(\.additions).reduce(0, +), deletions: stats.map(\.deletions).reduce(0, +))
            }
        }
        .padding(.bottom, continues ? 8 : 0)
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
            Text("+\(additions)").foregroundStyle(Theme.completed)
            Text("-\(deletions)").foregroundStyle(Theme.danger)
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
                Image(glyph: "photo.badge.exclamationmark").foregroundStyle(Theme.faint)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: 240, maxHeight: 240)
        .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius))
        .task {
            do {
                let data = try await Attachments.download(path, from: deviceId, via: app.connection)
                image = Image(data: data)
                failed = image == nil
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
