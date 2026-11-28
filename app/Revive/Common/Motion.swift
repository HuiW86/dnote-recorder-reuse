import SwiftUI
#if canImport(UIKit)
import UIKit
#else
import AppKit
#endif

/// The app's one motion language (docs/design-spec.md §2.3), shared by the iPhone and the Mac
/// app (ADR-011). Views animate only through these tokens and helpers; scripts/check-motion.sh
/// fails CI on a raw `withAnimation`, `.animation(` or `.transition(` anywhere else under
/// app/Revive or app/ReviveMac.
///
/// Four kinds of change, four curves. None bounces: the app is a quiet tool, and a change the
/// user makes many times a minute must never be slower than the tap that caused it.
enum Motion {
    /// The answer to a tap: a tick, a star, a selected chip, a pressed key, a swapped icon.
    /// Short enough that a second tap lands on a finished state.
    static let tap = Animation.snappy(duration: 0.18)
    /// Something on the page appears, leaves, grows, shrinks or changes what it says: a status
    /// line, a spinner giving way to a result, a row added or removed.
    static let standard = Animation.smooth(duration: 0.3)
    /// A card that floats over the page from an edge (toast, 留着 / 不要): it travels further,
    /// so it takes a little longer and settles instead of stopping.
    static let overlay = Animation.smooth(duration: 0.38)
    /// The page moving by itself to follow along (the transcript line being played).
    static let follow = Animation.smooth(duration: 0.45)
    /// The connect guide's drawing of the card's white light; the card itself blinks about
    /// once a second.
    static let blink = Animation.easeInOut(duration: 0.5).repeatForever(autoreverses: true)

    /// With Reduce Motion on, nothing travels or scales: changes cross-fade in this time.
    static let reducedFade = Animation.easeInOut(duration: 0.2)

    /// How far a pressed control sinks.
    static let pressedScale: CGFloat = 0.94

    /// `animation`, or a plain cross-fade when the user asked for less motion.
    static func resolved(_ animation: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? reducedFade : animation
    }

    /// The system's Reduce Motion setting, for code outside a view (`withMotion`).
    @MainActor static var systemReducesMotion: Bool {
        #if canImport(UIKit)
        UIAccessibility.isReduceMotionEnabled
        #else
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        #endif
    }
}

/// `withAnimation` through a Motion token, honouring Reduce Motion. The only way views start an
/// explicit animation.
@MainActor
@discardableResult
func withMotion<Result>(_ animation: Animation, _ body: () throws -> Result) rethrows -> Result {
    try withAnimation(Motion.resolved(animation, reduceMotion: Motion.systemReducesMotion), body)
}

/// Where an appearing view comes from. Each case says something about the change; with Reduce
/// Motion on, every one of them becomes a cross-fade.
enum MotionEntrance {
    /// Fades in place: a line of text or a status that replaces another.
    case fade
    /// From the top edge: a card floating over the page (toast, 留着 / 不要).
    case top
    /// From the bottom edge: the Mac window's toast, which sits at the bottom.
    case bottom
    /// Grows from its own centre: a mark that confirms something (a check, a star, a spinner
    /// giving way to an icon).
    case pop

    func transition(reduceMotion: Bool) -> AnyTransition {
        if reduceMotion { return .opacity }
        switch self {
        case .fade: return .opacity
        case .top: return .move(edge: .top).combined(with: .opacity)
        case .bottom: return .move(edge: .bottom).combined(with: .opacity)
        case .pop: return .scale(scale: 0.6).combined(with: .opacity)
        }
    }
}

private struct MotionAnimation<Value: Equatable>: ViewModifier {
    let animation: Animation
    let value: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.animation(Motion.resolved(animation, reduceMotion: reduceMotion), value: value)
    }
}

private struct MotionTransition: ViewModifier {
    let entrance: MotionEntrance
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func body(content: Content) -> some View {
        content.transition(entrance.transition(reduceMotion: reduceMotion))
    }
}

extension View {
    /// `.animation(_:value:)` through a Motion token, honouring Reduce Motion.
    func motion<Value: Equatable>(_ animation: Animation, value: Value) -> some View {
        modifier(MotionAnimation(animation: animation, value: value))
    }

    /// `.transition(_:)` from the app's entrances, honouring Reduce Motion.
    func motionTransition(_ entrance: MotionEntrance) -> some View {
        modifier(MotionTransition(entrance: entrance))
    }
}

/// A custom-drawn control (record key, the recording page's round buttons, filter chips, player
/// keys) answers the finger: it sinks while held and comes back when released. It follows the
/// touch, so letting go halfway through simply reverses it. With Reduce Motion on it dims instead.
struct PressableButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed && isEnabled
        configuration.label
            .scaleEffect(pressed && !reduceMotion ? Motion.pressedScale : 1)
            .opacity(pressed && reduceMotion ? 0.6 : 1)
            .animation(Motion.resolved(Motion.tap, reduceMotion: reduceMotion), value: pressed)
    }
}

extension ButtonStyle where Self == PressableButtonStyle {
    static var pressable: PressableButtonStyle { PressableButtonStyle() }
}
