import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

extension Image {
    init?(data: Data) {
        #if canImport(UIKit) || os(Android)
        guard let decoded = UIImage(data: data) else { return nil }
        self.init(uiImage: decoded)
        #else
        return nil
        #endif
    }
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
}
