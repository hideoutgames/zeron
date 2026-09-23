#if !SKIP_BRIDGE
import Foundation
import SwiftUI
import SkipKit
#if SKIP
import androidx.compose.runtime.Composable
#endif

/// Bridges the system photo, camera and file pickers to the composer.
/// `open` asks for a picker; every chosen item comes back as bytes plus a name.
public final class AttachmentPicker {
    public var onPick: (String, Data) -> Void = { _, _ in }
    var present: ((String) -> Void)?

    public init() {
    }

    /// `source` is "photos", "camera" or "files".
    public func open(_ source: String) {
        if let present {
            present(source)
        }
    }
}

#if SKIP
/// Hosts `PickerHost` inside a native `ComposeView` on Android.
public struct PickerComposer: ContentComposer {
    let picker: AttachmentPicker

    public init(picker: AttachmentPicker) {
        self.picker = picker
    }

    // SKIP @nobridge
    @Composable public func Compose(context: ComposeContext) {
        PickerHost(picker: picker).Compose(context: context)
    }
}
#endif

/// Zero-size view carrying the SkipKit picker modifiers. Native iOS embeds it directly;
/// Android reaches it through `PickerComposer`.
public struct PickerHost: View {
    let picker: AttachmentPicker

    @State var photos = false
    @State var camera = false
    @State var files = false
    @State var imageURLs: [URL] = []
    @State var fileURLs: [URL] = []
    @State var fileNames: [String] = []
    @State var fileTypes: [String] = []

    public init(picker: AttachmentPicker) {
        self.picker = picker
    }

    public var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                picker.present = { source in
                    switch source {
                    case "camera": camera = true
                    case "files": files = true
                    default: photos = true
                    }
                }
            }
            .withMediaPicker(type: .library, isPresented: $photos, allowsMultipleSelection: true, selectedImageURLs: $imageURLs)
            .withMediaPicker(type: .camera, isPresented: $camera, allowsMultipleSelection: false, selectedImageURLs: $imageURLs)
            .withDocumentPicker(isPresented: $files, allowedContentTypes: [.item], allowsMultipleSelection: true, selectedDocumentURLs: $fileURLs, selectedFilenames: $fileNames, selectedFileMimeTypes: $fileTypes)
            .onChange(of: imageURLs) {
                deliver(imageURLs, names: imageURLs.map { $0.lastPathComponent })
                imageURLs = []
            }
            .onChange(of: fileURLs) {
                deliver(fileURLs, names: fileNames)
                fileURLs = []
            }
    }

    private func deliver(_ urls: [URL], names: [String]) {
        for (index, url) in urls.enumerated() {
            guard let data = load(url) else { continue }
            let name = index < names.count && !names[index].isEmpty ? names[index] : url.lastPathComponent
            picker.onPick(name, data)
        }
    }

    private func load(_ url: URL) -> Data? {
        #if SKIP
        let resolver = ProcessInfo.processInfo.androidContext.contentResolver
        guard let stream = resolver.openInputStream(android.net.Uri.parse(url.absoluteString)) else { return nil }
        defer { stream.close() }
        return Data(platformValue: stream.readBytes())
        #else
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        return try? Data(contentsOf: url)
        #endif
    }
}
#endif
