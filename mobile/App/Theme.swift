import SwiftUI

/// Zeron's desktop palette: neutral greys, indigo accent, one colour per session state.
enum Theme {
    static let bg = Color(white: 0.06)
    static let surface = Color(white: 0.13)
    static let raised = Color(white: 0.235)
    static let border = Color.white.opacity(0.08)
    static let borderStrong = Color.white.opacity(0.14)

    static let text = Color(white: 0.922)
    static let muted = Color(white: 0.708)
    static let faint = Color(white: 0.556)

    static let accent = Color(red: 0.49, green: 0.53, blue: 1)
    static let danger = Color(red: 1, green: 0.39, blue: 0.4)
    static let warning = Color(red: 1, green: 0.73, blue: 0)
    static let working = Color(red: 0.98, green: 0.39, blue: 0.71)
    static let completed = Color(red: 0, green: 0.83, blue: 0.57)

    static let bubbleRadius: CGFloat = 22
    static let panelRadius: CGFloat = 10
    static let controlRadius: CGFloat = 6
}

extension View {
    /// A flat panel: raised surface with a hairline border.
    func panel(_ fill: Color = Theme.surface, radius: CGFloat = Theme.panelRadius) -> some View {
        background(fill, in: RoundedRectangle(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).stroke(Theme.border, lineWidth: 1))
    }
}
