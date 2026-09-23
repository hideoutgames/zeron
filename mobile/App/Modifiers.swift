import SwiftUI
import ZeronPickers
#if canImport(UIKit)
import UIKit
#endif

extension Image {
    /// An SF Symbol; on Android, the closest icon Skip ships when the symbol is not mapped.
    init(glyph name: String) {
        #if os(Android)
        self.init(systemName: Glyph.android[name] ?? name)
        #else
        self.init(systemName: name)
        #endif
    }

    init?(data: Data) {
        #if canImport(UIKit) || os(Android)
        guard let decoded = UIImage(data: data) else { return nil }
        self.init(uiImage: decoded)
        #else
        return nil
        #endif
    }
}

enum Glyph {
    static let android: [String: String] = [
        "arrow.clockwise": "arrow.clockwise.circle",
        "arrow.up.circle.fill": "paperplane.fill",
        "brain": "ellipsis",
        "camera": "camera.viewfinder",
        "checklist": "checkmark",
        "circle.dotted": "ellipsis",
        "doc.fill": "list.bullet",
        "doc.text": "list.bullet",
        "exclamationmark.circle.fill": "exclamationmark.triangle.fill",
        "folder": "list.bullet",
        "globe": "location",
        "lock.slash": "lock",
        "photo.badge.exclamationmark": "exclamationmark.triangle",
        "photo.on.rectangle": "person.crop.square",
        "play.circle": "play",
        "plus.forwardslash.minus": "pencil",
        "puzzlepiece.extension": "wrench",
        "questionmark.circle.fill": "info.circle.fill",
        "questionmark.square.dashed": "info.circle",
        "rectangle.portrait.and.arrow.right": "arrow.forward.square",
        "stop.circle": "xmark",
        "terminal": "chevron.right",
        "xmark.circle": "xmark",
        "xmark.circle.fill": "xmark",
    ]
}

/// Modifiers missing on Android (Skip) or macOS (where the package builds for tests).
extension View {
    func inlineTitle() -> some View {
        #if os(macOS)
        self
        #else
        navigationBarTitleDisplayMode(.inline)
        #endif
    }

    func urlKeyboard() -> some View {
        #if os(macOS)
        self
        #else
        keyboardType(.URL).textInputAutocapitalization(.never)
        #endif
    }

    func selectable() -> some View {
        #if os(Android)
        self
        #else
        textSelection(.enabled)
        #endif
    }

    func combinedAccessibility() -> some View {
        #if os(Android)
        self
        #else
        accessibilityElement(children: .combine)
        #endif
    }

    func truncatedMiddle() -> some View {
        #if os(Android)
        self
        #else
        truncationMode(.middle)
        #endif
    }

    /// Makes the whole frame, padding included, respond to taps.
    func tappable() -> some View {
        #if os(Android)
        self
        #else
        contentShape(Rectangle())
        #endif
    }

    /// Hosts the photo, camera and file pickers that `picker.open` presents.
    func attachmentPicker(_ picker: AttachmentPicker) -> some View {
        #if os(Android)
        background(ComposeView { PickerComposer(picker: picker) })
        #else
        background(PickerHost(picker: picker))
        #endif
    }

    /// A circular icon control, filled or quiet.
    func circleControl(_ fill: Color, size: CGFloat = 32) -> some View {
        frame(width: size, height: size)
            .background(fill, in: Circle())
    }
}
