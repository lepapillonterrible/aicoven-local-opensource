import SwiftUI

/// The one line a turn shows while it runs: ring, what it is doing, Details,
/// and Stop, with no elapsed time. A turn that is stopping says so and
/// offers no Stop.
struct TurnStatusLineView: View {
    let turn: TurnEngine.Activity
    /// Opens the work trace.
    let onDetails: () -> Void
    let onStop: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        // At accessibility text sizes Details and Stop sit under the text,
        // so the text keeps the column's width.
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: Spacing.xxs))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: Spacing.sm))
        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
            StatusRing(isTurning: true)
                .accessibilityHidden(true)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }

            layout {
                Text(turn.message)
                    .font(.aicovenBody)
                    .foregroundStyle(Color.aicovenTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                    .accessibilityIdentifier("status-line-text")

                HStack(spacing: Spacing.sm) {
                    Button("Details", action: onDetails)
                        .buttonStyle(.textLink)
                        .accessibilityIdentifier("status-line-details")
                        .accessibilityHint("Shows the steps behind this answer")
                    if !turn.isStopping {
                        Button("Stop", action: onStop)
                            .buttonStyle(.textLink)
                            .keyboardShortcut(".", modifiers: .command)
                            .accessibilityIdentifier("status-line-stop")
                            .accessibilityHint("Stops this reply")
                    }
                }
                .font(.aicovenBodySmall)
                .fixedSize()
            }

            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
        // VoiceOver hears each new status once, however many windows show
        // this turn. A turn in a thread no window shows is not announced.
        .onChange(of: turn.message) { _, message in
            // The engine says "Stopping" itself, when Stop is pressed.
            guard !turn.isStopping else { return }
            TurnEngine.shared.announceStatus(message, of: turn.turnID)
        }
    }
}

/// The turning ring: turns while work is happening, and is still under
/// Reduce Motion, where the text beside it carries the state.
struct StatusRing: View {
    let isTurning: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: !isTurning || reduceMotion)) { context in
            let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1)
            ZStack {
                Circle()
                    .stroke(Color.aicovenBorder, lineWidth: 2)
                if isTurning {
                    Circle()
                        .trim(from: 0, to: 0.25)
                        .stroke(Color.aicovenTeal, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(reduceMotion ? 0 : turn * 360))
                }
            }
        }
        .frame(width: 12, height: 12)
    }
}

/// Underlined small text in the secondary colour: Details, Stop, a receipt.
/// A 44 pt target on touch.
struct TextLinkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .underline()
            .foregroundStyle(Color.aicovenTextSecondary)
            .opacity(configuration.isPressed ? 0.6 : 1)
        #if os(iOS)
            .frame(minHeight: 44)
        #endif
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == TextLinkButtonStyle {
    static var textLink: TextLinkButtonStyle {
        TextLinkButtonStyle()
    }
}
