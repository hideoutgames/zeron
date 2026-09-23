import SwiftUI

/// Text modifiers Skip does not support on Android yet.
extension View {
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
