import SwiftUI
import ZeronClient
import ZeronGenerated

/// The streaming message list. Pinned to the newest message while it grows.
struct TranscriptView: View {
    let transcript: Transcript
    let chat: Chat

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(transcript.entries, id: \.id) { entry in
                        MessageView(entry: entry, chat: chat, transcript: transcript)
                            .id(entry.id)
                    }
                    ForEach(transcript.pending.filter { $0.failed == nil }) { item in
                        if let text = item.prompt {
                            UserBubble(text: text)
                                .opacity(0.65)
                                .id(item.id)
                        }
                    }
                    Color.clear.frame(height: 1).id("tail")
                }
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.bg)
            .overlay {
                if !transcript.loaded {
                    ProgressView()
                }
            }
            .onChange(of: tailSignature) { _, _ in
                proxy.scrollTo("tail", anchor: .bottom)
            }
        }
    }

    private var tailSignature: Int {
        var hasher = Hasher()
        hasher.combine(transcript.entries.count)
        hasher.combine(transcript.pending.count)
        if let last = transcript.entries.last {
            hasher.combine(last.parts.count)
            if case .text(let text) = last.parts.last { hasher.combine(text.text.utf8.count) }
        }
        return hasher.finalize()
    }
}

extension Transcript.Pending {
    var prompt: String? {
        switch command {
        case .run(let run): run.request.prompt
        case .steer(let steer): steer.prompt
        case .interrupt, .respondInput: nil
        }
    }
}
