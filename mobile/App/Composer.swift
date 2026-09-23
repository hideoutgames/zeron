import SwiftUI
#if canImport(PhotosUI)
import PhotosUI
#endif
import ZeronClient
import ZeronGenerated

/// Text in, commands out. While the agent works, text steers and the stop glyph interrupts.
struct Composer: View {
    let transcript: Transcript
    let chat: Chat
    let status: SessionStatus?

    @Environment(AppModel.self) var app
    @State var text = ""
    @State var images: [Data] = []
    @State var uploading = false

    private var working: Bool { status == .working }
    private var canSend: Bool { !uploading && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty) }

    var body: some View {
        VStack(spacing: 8) {
            if !images.isEmpty {
                AttachmentStrip(images: $images)
            }
            HStack(alignment: .bottom, spacing: 10) {
                ImagePicker(images: $images)
                TextField(working ? "Steer" : "Message", text: $text, axis: .vertical)
                    .lineLimit(1...6)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.fill.tertiary, in: RoundedRectangle(cornerRadius: 18))
                    .onSubmit(submit)
                if working {
                    Button(action: transcript.interrupt) {
                        Image(systemName: "stop.circle.fill").font(.title)
                    }
                    .accessibilityLabel("Stop")
                }
                Button(action: submit) {
                    Image(systemName: working ? "arrow.turn.up.right.circle.fill" : "arrow.up.circle.fill").font(.title)
                }
                .disabled(!canSend)
                .accessibilityLabel(working ? "Steer" : "Send")
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.bar)
        .disabled(app.connection.status != .connected)
    }

    private func submit() {
        guard canSend else { return }
        let prompt = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let pending = images
        text = ""
        images = []
        if working {
            transcript.steer(prompt)
            return
        }
        guard !pending.isEmpty else {
            transcript.send(prompt, in: chat)
            return
        }
        uploading = true
        Task {
            defer { uploading = false }
            var paths: [String] = []
            for (index, data) in pending.enumerated() {
                let name = "image-\(index + 1).jpg"
                if let path = try? await Attachments.upload(data, named: name, to: chat.deviceId, via: app.connection) {
                    paths.append(path)
                }
            }
            transcript.send(prompt, attachments: paths, in: chat)
        }
    }
}

struct AttachmentStrip: View {
    @Binding var images: [Data]

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(images.indices, id: \.self) { index in
                    Thumbnail(data: images[index])
                        .overlay(alignment: .topTrailing) {
                            Button { images.remove(at: index) } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.white, .black.opacity(0.6))
                            }
                            .accessibilityLabel("Remove image")
                            .offset(x: 6, y: -6)
                        }
                }
            }
            .padding(.top, 6)
        }
        .scrollIndicators(.hidden)
    }
}

struct Thumbnail: View {
    let data: Data

    var body: some View {
        Group {
            if let image = UIImage(data: data) {
                Image(uiImage: image).resizable().scaledToFill()
            } else {
                Image(systemName: "photo")
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

/// Photo library access. Only offered where the platform layer supports it.
struct ImagePicker: View {
    @Binding var images: [Data]

    #if canImport(PhotosUI)
    @State var selection: [PhotosPickerItem] = []

    var body: some View {
        PhotosPicker(selection: $selection, maxSelectionCount: 4, matching: .images) {
            Image(systemName: "paperclip").font(.title2)
        }
        .accessibilityLabel("Attach image")
        .onChange(of: selection) { _, items in
            guard !items.isEmpty else { return }
            selection = []
            Task {
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self) {
                        images.append(data)
                    }
                }
            }
        }
    }
    #else
    var body: some View {
        EmptyView()
    }
    #endif
}
