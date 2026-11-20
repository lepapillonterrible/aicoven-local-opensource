import SwiftUI

/// The coven switcher's list, as the cloud app's: Strix first, then the
/// person's covens in their own order, each with one line of what is moving
/// or waiting there and an unread dot, then New Coven, then the person's
/// row. A popover from the sidebar's switcher.
///
/// A coven is moved by dragging it onto another row, or with Move Up and
/// Move Down in its context menu (and for VoiceOver). Strix does not move,
/// and nothing moves above it.
struct CovenSwitcherList: View {
    /// The covens in the person's order. Strix is not among them.
    let covens: [Coven]
    let rowMinHeight: CGFloat
    let popoverWidth: CGFloat
    let selected: ShellScope
    /// What is moving or waiting in a scope.
    let current: (ShellScope) -> ConversationActivity?
    let hasUnread: (ShellScope) -> Bool
    let personName: String
    let onSelect: (ShellScope) -> Void
    let onCreateCoven: () -> Void
    let onOpenSettings: () -> Void
    /// Moves a coven to a place among the covens.
    let onMoveCoven: (_ covenID: String, _ index: Int) -> Void

    /// The row a dragged coven is over.
    @State private var dropTarget: ShellScope?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    row(.strix, coven: nil, name: "Strix")
                    ForEach(Array(covens.enumerated()), id: \.element.id) { index, coven in
                        row(.coven(coven.id), coven: coven, name: coven.name)
                            .draggable(coven.id)
                            .contextMenu { moveButtons(coven, at: index) }
                            .accessibilityActions { moveButtons(coven, at: index) }
                    }
                }
                .padding(Spacing.xs)
            }
            // The rows' height, with their current lines, up to a cap.
            .frame(
                minHeight: min(420, CGFloat(covens.count + 1) * (rowMinHeight + 2) + currentLinesHeight + Spacing.xs * 2),
                maxHeight: 420
            )
            Divider()
            VStack(alignment: .leading, spacing: 2) {
                action(title: "New Coven…", systemImage: "plus", action: onCreateCoven)
                action(title: personName, systemImage: "person.crop.circle", action: onOpenSettings)
                    .accessibilityHint("Opens Settings")
            }
            .padding(Spacing.xs)
        }
        .frame(width: popoverWidth)
    }

    /// The height the rows' current lines add, at the caption's default size.
    private var currentLinesHeight: CGFloat {
        let scopes = [ShellScope.strix] + covens.map { .coven($0.id) }
        return CGFloat(scopes.count(where: { current($0) != nil })) * 16
    }

    private func row(_ scope: ShellScope, coven: Coven?, name: String) -> some View {
        let currentActivity = current(scope)
        let unread = hasUnread(scope)
        return Button {
            onSelect(scope)
        } label: {
            HStack(spacing: Spacing.sm) {
                CovenIcon(coven: coven, size: 28)
                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(.aicovenH2)
                        .foregroundColor(.aicovenTextPrimary)
                        .lineLimit(1)
                    HStack(spacing: Spacing.xxs) {
                        if currentActivity?.isWaiting == true { WaitingMark() }
                        ConversationActivityCaption(activity: currentActivity)
                    }
                }
                Spacer(minLength: 0)
                if unread {
                    ActivityDot()
                }
                if scope == selected {
                    Image(systemName: "checkmark")
                        .font(.aicovenCaption.weight(.semibold))
                        .foregroundColor(.aicovenTextSecondary)
                }
            }
            .padding(.horizontal, Spacing.sm)
            .frame(minHeight: rowMinHeight)
            .background(
                RoundedRectangle(cornerRadius: BorderRadius.sm)
                    .fill(dropTarget == scope ? Color.aicovenSelected : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // Dropping a coven on a row puts it in that row's place; on Strix,
        // which always stays first, it becomes the first coven after it.
        .dropDestination(for: String.self) { ids, _ in
            guard let dragged = ids.first, let index = Self.dropIndex(of: dragged, onto: scope, in: covens) else { return false }
            onMoveCoven(dragged, index)
            return true
        } isTargeted: { isTargeted in
            if isTargeted {
                dropTarget = scope
            } else if dropTarget == scope {
                dropTarget = nil
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(name)
        .accessibilityValue(Self.accessibilityValue(current: currentActivity, unread: unread))
        .accessibilityAddTraits(scope == selected ? .isSelected : [])
    }

    /// Where among the covens a coven dropped on a row goes: that row's
    /// place, or first when dropped on Strix (which stays above them all).
    /// Nil for what is not one of the covens, or a row that is no longer
    /// there.
    static func dropIndex(of dragged: String, onto scope: ShellScope, in covens: [Coven]) -> Int? {
        guard covens.contains(where: { $0.id == dragged }) else { return nil }
        guard let covenID = scope.covenID else { return 0 }
        return covens.firstIndex { $0.id == covenID }
    }

    /// Move Up and Move Down, for the context menu and VoiceOver: the paths
    /// that do not need a drag.
    @ViewBuilder
    private func moveButtons(_ coven: Coven, at index: Int) -> some View {
        if CovenOrder.canMove(coven.id, up: true, in: covens) {
            Button("Move Up") { onMoveCoven(coven.id, index - 1) }
        }
        if CovenOrder.canMove(coven.id, up: false, in: covens) {
            Button("Move Down") { onMoveCoven(coven.id, index + 1) }
        }
    }

    /// What VoiceOver reads after a scope's name: what moves or waits
    /// there, and whether it holds a reply not yet seen.
    static func accessibilityValue(current: ConversationActivity?, unread: Bool) -> String {
        var parts: [String] = []
        if let current { parts.append(current.accessibilityWords) }
        if unread { parts.append("Unread") }
        return parts.joined(separator: ", ")
    }

    private func action(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.aicovenH3)
                .foregroundColor(.aicovenTextPrimary)
                .frame(maxWidth: .infinity, minHeight: rowMinHeight, alignment: .leading)
                .padding(.horizontal, Spacing.sm)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Another scope's current under the name of the scope on screen: "Hiring
/// Reading 14 portfolios", with the waiting mark before the turn's waiting
/// words ("Needs your OK").
struct OtherCovenCurrentLine: View {
    let name: String
    let current: ConversationActivity

    var body: some View {
        HStack(spacing: Spacing.xxs) {
            Text(name)
                .font(.aicovenCaption.weight(.semibold))
                .foregroundColor(.aicovenTextSecondary)
                .lineLimit(1)
            if current.isWaiting { WaitingMark() }
            ConversationActivityCaption(activity: current)
        }
        .accessibilityHidden(true)
    }
}
