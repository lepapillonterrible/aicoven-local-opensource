import SwiftUI

/// The mark at the start of a thread row: a turning ring while work
/// happens, a still ring when it is paused, the waiting mark when it waits
/// for the person, a water dot for a reply not yet seen. A row with none of
/// these shows `idle` there (its own icon, or nothing).
struct ConversationActivityGlyph<Idle: View>: View {
    let activity: ConversationActivity?
    @ViewBuilder var idle: () -> Idle

    var body: some View {
        Group {
            switch activity {
            case .moving:
                StatusRing(isTurning: true)
            case .paused:
                StatusRing(isTurning: false)
            case .waiting:
                WaitingMark()
            case .unread:
                ActivityDot()
            case .broken, .unsent, nil:
                idle()
            }
        }
        .frame(minWidth: 12, minHeight: 12)
        .accessibilityHidden(true)
    }
}

/// The caption line under a thread's title, in the turn's own words: water
/// for moving, semibold secondary ink for waiting, rust for broken. Nothing
/// for a finished or unread thread. VoiceOver reads the words from the row.
struct ConversationActivityCaption: View {
    let activity: ConversationActivity?
    var font: Font = .aicovenCaption
    /// `.increased` on a selected row's system highlight, where water and
    /// rust would not read; the caption then takes the highlight's own ink.
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        if let activity, let caption = activity.caption {
            Text(caption)
                .font(activity.isWaiting ? font.weight(.semibold) : font)
                .foregroundStyle(style(activity))
                .lineLimit(1)
                .accessibilityHidden(true)
        }
    }

    private func style(_ activity: ConversationActivity) -> AnyShapeStyle {
        if prominence == .increased { return AnyShapeStyle(.secondary) }
        return switch activity {
        case .moving: AnyShapeStyle(Color.aicovenWater)
        case .broken: AnyShapeStyle(Color.aicovenError)
        case .waiting, .paused, .unsent, .unread: AnyShapeStyle(Color.aicovenTextSecondary)
        }
    }
}

/// The 7 pt water dot for unread; in the highlight's own ink on a selected
/// row.
struct ActivityDot: View {
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        Circle()
            .fill(prominence == .increased ? AnyShapeStyle(.primary) : AnyShapeStyle(Color.aicovenWater))
            .frame(width: 7, height: 7)
            .accessibilityHidden(true)
    }
}

/// The waiting mark: a 7 pt secondary-ink square with 2 pt corners, for
/// what waits for the person. Never a count.
struct WaitingMark: View {
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        RoundedRectangle(cornerRadius: 2)
            .fill(prominence == .increased ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.aicovenTextSecondary))
            .frame(width: 7, height: 7)
            .accessibilityHidden(true)
    }
}

extension View {
    /// What VoiceOver reads after a thread row's title: what the thread is
    /// doing, or that it holds a reply not yet seen.
    func threadActivityValue(_ activity: ConversationActivity?) -> some View {
        accessibilityValue(activity?.accessibilityWords ?? "")
    }
}

/// A thread row's date in tertiary ink; on a selected row's system
/// highlight, in the highlight's own ink.
struct ThreadRowDate: View {
    let date: Date
    @Environment(\.backgroundProminence) private var prominence

    var body: some View {
        Text(VisitWords.rowDate(date))
            .font(.aicovenCaption)
            .foregroundStyle(prominence == .increased ? AnyShapeStyle(.secondary) : AnyShapeStyle(Color.aicovenTextTertiary))
    }
}
