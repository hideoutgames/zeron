import SwiftUI
import ZeronClient
import ZeronGenerated
import ZeronPickers

/// Text in, commands out. A capsule at rest; a card once focused, long or carrying attachments.
/// While the agent works, text steers and the stop control interrupts.
struct Composer: View {
    let transcript: Transcript
    let chat: Chat
    let status: SessionStatus?

    @Environment(AppModel.self) var app
    @State var text = ""
    @State var attachments: [Attachment] = []
    @State var uploading = false
    @State var failed = false
    @State var picker = AttachmentPicker()
    @FocusState var focused: Bool

    private var working: Bool { status == .working }
    private var empty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty }
    private var canSend: Bool { !uploading && !empty }
    private var expanded: Bool { focused || !attachments.isEmpty || text.contains("\n") || text.count > 26 }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !attachments.isEmpty {
                AttachmentStrip(attachments: $attachments)
            }
            HStack(alignment: .bottom, spacing: 8) {
                if !expanded { attach }
                TextField(working ? "Steer" : "Message", text: $text, axis: .vertical)
                    .lineLimit(expanded ? 8 : 1)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .foregroundStyle(Theme.text)
                    .padding(.horizontal, 6)
                    .frame(minHeight: 32)
                    .onSubmit(submit)
                if !expanded { action }
            }
            if expanded {
                HStack(spacing: 8) {
                    attach
                    if failed {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.danger)
                            .accessibilityLabel("Upload failed")
                    }
                    Spacer()
                    action
                }
            }
        }
        .padding(8)
        .panel(Theme.surface, radius: expanded ? 20 : 24)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Theme.bg)
        .attachmentPicker(picker)
        .onAppear {
            picker.onPick = { name, data in attachments.append(Attachment(name: name, data: data)) }
        }
        .disabled(app.connection.status != .connected)
    }

    private var attach: some View {
        Menu {
            Button { picker.open("photos") } label: { Label { Text("Photos") } icon: { Image(glyph: "photo.on.rectangle") } }
            Button { picker.open("camera") } label: { Label { Text("Camera") } icon: { Image(glyph: "camera") } }
            Button { picker.open("files") } label: { Label { Text("Files") } icon: { Image(glyph: "folder") } }
        } label: {
            Image(systemName: "plus")
                .foregroundStyle(Theme.muted)
                .circleControl(Theme.raised)
        }
        .accessibilityLabel("Attach")
    }

    @ViewBuilder private var action: some View {
        if working && empty {
            Button(action: transcript.interrupt) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Theme.bg)
                    .frame(width: 10, height: 10)
                    .circleControl(Theme.text)
            }
            .accessibilityLabel("Stop")
        } else {
            Button(action: submit) {
                Image(systemName: uploading ? "ellipsis" : "paperplane.fill")
                    .font(.subheadline)
                    .foregroundStyle(canSend ? Theme.bg : Theme.faint)
                    .circleControl(canSend ? Theme.text : Theme.raised)
            }
            .disabled(!canSend)
            .accessibilityLabel(working ? "Steer" : "Send")
        }
    }

    private func submit() {
        guard canSend else { return }
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let files = attachments
        text = ""
        attachments = []
        failed = false
        if working {
            transcript.steer(prompt)
            return
        }
        guard !files.isEmpty else {
            transcript.send(prompt, in: chat)
            return
        }
        uploading = true
        Task {
            defer { uploading = false }
            do {
                var paths: [String] = []
                for file in files {
                    paths.append(try await Attachments.upload(file.data, named: file.name, to: chat.deviceId, via: app.connection))
                }
                transcript.send(prompt, attachments: paths, in: chat)
            } catch {
                text = prompt
                attachments = files
                failed = true
            }
        }
    }
}

/// Something the user picked to send along: a photo, a capture or a file.
struct Attachment: Identifiable {
    let id = UUID()
    let name: String
    let data: Data

    var image: Image? { Image(data: data) }
}

struct AttachmentStrip: View {
    @Binding var attachments: [Attachment]

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(attachments) { attachment in
                    Thumbnail(attachment: attachment)
                        .overlay(alignment: .topTrailing) {
                            Button { attachments.removeAll { $0.id == attachment.id } } label: {
                                Image(systemName: "xmark")
                                    .font(.caption2)
                                    .foregroundStyle(Theme.text)
                                    .circleControl(Theme.bg.opacity(0.8), size: 20)
                            }
                            .accessibilityLabel("Remove")
                            .offset(x: 4, y: -4)
                        }
                }
            }
            .padding(6)
        }
    }
}

struct Thumbnail: View {
    let attachment: Attachment

    var body: some View {
        Group {
            if let image = attachment.image {
                image.resizable().scaledToFill()
            } else {
                VStack(spacing: 4) {
                    Image(glyph: "doc.fill")
                    Text(URL(fileURLWithPath: attachment.name).pathExtension.lowercased())
                        .font(.caption2.monospaced())
                }
                .foregroundStyle(Theme.muted)
            }
        }
        .frame(width: 56, height: 56)
        .background(Theme.raised)
        .clipShape(RoundedRectangle(cornerRadius: Theme.panelRadius))
        .accessibilityLabel(Text(attachment.name))
    }
}
