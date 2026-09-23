import SwiftUI
import ZeronClient
import ZeronGenerated

/// Sessions grouped by space. With a `selection` it acts as a sidebar; without, rows push a chat.
struct ChatListView: View {
    var selection: Binding<String?>? = nil

    @Environment(AppModel.self) var app

    var body: some View {
        List {
            ForEach(sections, id: \.space?.id) { section in
                Section {
                    ForEach(section.chats, id: \.id) { chat in
                        row(chat)
                            .listRowBackground(selection?.wrappedValue == chat.id ? Theme.raised : Theme.bg)
                    }
                } header: {
                    Text(section.space?.title ?? "").foregroundStyle(Theme.faint)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .overlay {
            if !app.workspace.loaded {
                ConnectionBadge(status: app.connection.status)
                    .scaleEffect(2)
            }
        }
        .navigationTitle("Sessions")
        .navigationDestination(for: String.self) { chatId in
            ChatView(chatId: chatId)
        }
        .toolbar {
            Menu {
                Button(role: .destructive, action: app.signOut) {
                    Label { Text("Sign Out") } icon: { Image(glyph: "rectangle.portrait.and.arrow.right") }
                }
            } label: {
                ConnectionBadge(status: app.connection.status)
            }
        }
    }

    @ViewBuilder private func row(_ chat: Chat) -> some View {
        let row = ChatRow(chat: chat, indicator: app.workspace.indicator(for: chat))
        if let selection {
            Button { selection.wrappedValue = chat.id } label: { row }
                .buttonStyle(.plain)
        } else {
            NavigationLink(value: chat.id) { row }
        }
    }

    private struct ChatSection {
        let space: Space?
        let chats: [Chat]
    }

    private var sections: [ChatSection] {
        let grouped = app.workspace.spaces.map { space in
            ChatSection(space: space, chats: app.workspace.chats(in: space))
        }
        let loose = app.workspace.chats(in: nil).filter { $0.spaceId == nil }
        return (grouped + [ChatSection(space: nil, chats: loose)]).filter { !$0.chats.isEmpty }
    }
}

/// Desktop's session row: branch up top with the status corner, then the title, then a preview.
struct ChatRow: View {
    let chat: Chat
    let indicator: ChatIndicator

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Text(chat.branch ?? "")
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.faint)
                    .lineLimit(1)
                Spacer(minLength: 4)
                IndicatorDot(indicator: indicator)
            }
            Text(chat.displayTitle)
                .font(.body.weight(.medium))
                .foregroundStyle(Theme.text)
                .lineLimit(1)
            if let preview = chat.lastMessagePreview, !preview.isEmpty {
                Text(preview)
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 4)
        .combinedAccessibility()
    }
}

struct IndicatorDot: View {
    let indicator: ChatIndicator

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 8, height: 8)
            .accessibilityLabel(Text(label))
    }

    private var color: Color {
        switch indicator {
        case .working: Theme.working
        case .awaitingInput: Theme.warning
        case .errored: Theme.danger
        case .completed: Theme.completed
        case .idle: .clear
        }
    }

    private var label: String {
        switch indicator {
        case .working: "Working"
        case .awaitingInput: "Needs input"
        case .errored: "Failed"
        case .completed: "Unread"
        case .idle: ""
        }
    }
}

extension Chat {
    var displayTitle: String {
        title.flatMap { $0.isEmpty ? nil : $0 } ?? cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "Untitled"
    }
}

extension Space {
    var title: String {
        name ?? URL(fileURLWithPath: path).lastPathComponent
    }
}
