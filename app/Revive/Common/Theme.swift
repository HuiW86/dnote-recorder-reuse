import SwiftUI
import UIKit

/// Design tokens (docs/design-spec.md §2). Views take colours from here, not from literals.
enum Theme {
    /// Page background.
    static let paper = dynamic(light: 0xF6F1E6, dark: 0x14110F)
    /// Cards, input fields, the player bar.
    static let surface = dynamic(light: 0xFFFFFF, dark: 0x221E1B)
    /// Card outline.
    static let line = dynamic(light: 0xECE5D8, dark: 0x342E29)
    /// Body text and titles.
    static let ink = dynamic(light: 0x2A2420, dark: 0xF6F1E6)
    /// Secondary text, times.
    static let inkMuted = dynamic(light: 0x6B6058, dark: 0xA89E91)
    /// Selection, links, playback progress, icon strokes. One step darker than the icon red so
    /// text reaches 4.5:1 on `paper`.
    static let accent = dynamic(light: 0xB01C00, dark: 0xFF8A70)
    /// Icon tiles, the sentence being played.
    static let accentWash = dynamic(light: 0xFBE9E4, dark: 0x3A1E17)
    /// The app icon's red. Recording only, and only behind white glyphs, never as text.
    static let record = Color(uiColor: UIColor(hex: 0xF52100))
    /// Connected, stored.
    static let ok = dynamic(light: 0x3F8F4F, dark: 0x6FBF7C)

    enum Radius {
        static let card: CGFloat = 10
        static let control: CGFloat = 8
        static let chip: CGFloat = 6
    }

    private static func dynamic(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

private extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

extension View {
    /// The warm page background behind a `List` or `ScrollView`, replacing the system one.
    func paperBackground() -> some View {
        scrollContentBackground(.hidden).background(Theme.paper)
    }
}
