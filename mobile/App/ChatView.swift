import SwiftUI
import ZeronClient
import ZeronGenerated

struct ChatView: View {
    let chatId: String

    @Environment(AppModel.self) var app
    @State var transcript: Transcript?
    @State var showDiff = false

    private var chat: Chat? { app.workspace.chats.first { $0.id == chatId } }
    private var status: SessionStatus? { chat.flatMap { app.workspace.session(for: $0)?.status } }

    var body: some View {
        Group {
            if let transcript, let chat {
                VStack(spacing: 0) {
                    TranscriptView(transcript: transcript, chat: chat)
                    PendingBar(transcript: transcript)
                    Composer(transcript: transcript, chat: chat, status: status)
                }
            } else {
                ProgressView()
            }
        }
        .background(Theme.bg)
        .navigationTitle(chat?.displayTitle ?? "")
        .inlineTitle()
        .toolbar {
            if let status {
                SessionBadge(status: status)
            }
            if chat?.cwd != nil {
                Button { showDiff = true } label: {
                    Image(glyph: "plus.forwardslash.minus")
                }
                .accessibilityLabel("Changes")
            }
        }
        .sheet(isPresented: $showDiff) {
            if let chat {
                DiffView(chat: chat)
            }
        }
        .onAppear {
            if transcript == nil {
                let live = Transcript(chatId: chatId, connection: app.connection)
                live.start()
                transcript = live
            }
        }
        .onDisappear {
            transcript?.stop()
            transcript = nil
        }
    }
}

struct SessionBadge: View {
    let status: SessionStatus

    var body: some View {
        switch status {
        case .working:
            ProgressView().tint(Theme.working).accessibilityLabel("Working")
        case .awaitingInput:
            Image(glyph: "questionmark.circle.fill").foregroundStyle(Theme.warning).accessibilityLabel("Needs input")
        case .errored:
            Image(glyph: "exclamationmark.circle.fill").foregroundStyle(Theme.danger).accessibilityLabel("Failed")
        case .idle:
            EmptyView()
        }
    }
}

/// Commands the host has not confirmed. Failed ones can be retried or dropped.
struct PendingBar: View {
    let transcript: Transcript

    var body: some View {
        ForEach(transcript.pending.filter { $0.failed != nil }) { item in
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.warning)
                Text(item.failed ?? "").font(.footnote).foregroundStyle(Theme.muted).lineLimit(1)
                Spacer()
                Button { transcript.retry(item.id) } label: { Image(glyph: "arrow.clockwise") }
                    .accessibilityLabel("Retry")
                Button { transcript.discard(item.id) } label: { Image(systemName: "xmark") }
                    .accessibilityLabel("Discard")
            }
            .foregroundStyle(Theme.text)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .panel()
            .padding(.horizontal, 12)
            .background(Theme.bg)
        }
    }
}
