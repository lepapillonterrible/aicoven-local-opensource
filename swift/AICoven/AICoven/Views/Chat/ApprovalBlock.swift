import SwiftUI

/// The approval block: which thread asked and where, the question, exactly
/// what will happen, then Approve, Deny, and Details, which shows the tool's
/// name in place. What will happen is always there whole, scrolling when it
/// is long: Approve does exactly what it says. After an answer the block
/// says what happened instead of the buttons.
///
/// The caller sets the width: 262 pt beside the thread on the Mac and iPad,
/// the full width on the iPhone, where Approve and Deny are two 44 pt halves
/// with Details beneath. In 262 pt, a row that doesn't fit puts Details
/// beneath, then stacks all three.
struct ApprovalBlock: View {
    let approval: ToolApproval
    let phase: ToolApprovals.Phase
    /// The text's tallest height before it scrolls.
    var maxTextHeight: CGFloat = 240
    let onApprove: () -> Void
    let onDeny: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var showsDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            (
                Text(approval.threadTitle).fontWeight(.semibold).foregroundColor(.aicovenTextSecondary)
                    + Text(" in \(approval.covenName)").foregroundColor(.aicovenTextTertiary)
            )
            .font(.aicovenBodySmall)
            .padding(.bottom, Spacing.xxs)

            Text(approval.question)
                .font(.aicovenH2)
                .foregroundStyle(Color.aicovenTextPrimary)
                .fixedSize(horizontal: false, vertical: true)

            // The text as it is when it fits, else scrolling in that height.
            ViewThatFits(in: .vertical) {
                detailsText
                ScrollView { detailsText }
            }
            .frame(maxHeight: maxTextHeight)
            // Only as tall as the text, up to that height.
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 3)

            if showsDetails, phase == .asking {
                Divider()
                    .overlay(Color.aicovenBorder)
                    .padding(.top, Spacing.xs)
                Text("Tool: \(approval.toolName)")
                    .font(.aicovenBodySmall)
                    .foregroundStyle(Color.aicovenTextSecondary)
                    .textSelection(.enabled)
                    .padding(.top, Spacing.xs)
            }

            switch phase {
            case .asking:
                actions
                    .padding(.top, 11)
            case let .answered(outcome), let .leaving(outcome):
                outcomeRow(outcome)
                    .padding(.top, Spacing.xs)
            }
        }
        // The recipe's 12/14/11 inside the 1 pt border and 2 pt bottom edge.
        .padding(EdgeInsets(top: 13, leading: 15, bottom: 13, trailing: 15))
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(stone)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Approval from \(approval.threadTitle) in \(approval.covenName)"))
    }

    // MARK: - Actions

    private var isCompact: Bool {
        Self.spansTheWidth
    }

    /// True on the iPhone, where the block spans the width; on the iPad and
    /// the Mac it is 262 pt, whatever the window's width.
    static var spansTheWidth: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }

    /// 44 pt on touch, the recipe's 28 pt on the Mac.
    private var buttonMinHeight: CGFloat {
        #if os(iOS)
        44
        #else
        28
        #endif
    }

    @ViewBuilder
    private var actions: some View {
        if isCompact {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                HStack(spacing: Spacing.xs) {
                    approveButton
                    denyButton
                }
                detailsButton
            }
        } else if dynamicTypeSize.isAccessibilitySize {
            stackedActions
        } else {
            // When the three don't fit the block in one row, Details moves
            // under Approve and Deny, then all three stack, instead of a
            // label breaking mid-word.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Spacing.xs) {
                    approveButton
                    denyButton
                    Spacer(minLength: 0)
                    detailsButton
                }
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    HStack(spacing: Spacing.xs) {
                        approveButton
                        denyButton
                    }
                    detailsButton
                }
                stackedActions
            }
        }
    }

    private var stackedActions: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            approveButton
            denyButton
            detailsButton
        }
    }

    private var detailsText: some View {
        Text(approval.details)
            .font(.aicovenBodySmall)
            .foregroundStyle(Color.aicovenTextSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
    }

    /// Absent for something that can only be denied.
    @ViewBuilder
    private var approveButton: some View {
        if approval.canApprove {
            Button(action: onApprove) {
                Text("Approve").frame(maxWidth: isCompact ? .infinity : nil)
            }
            .buttonStyle(ApprovalButtonStyle(isPrimary: true, minHeight: buttonMinHeight))
            .accessibilityLabel(Text("Approve: \(approval.question)"))
        }
    }

    private var denyButton: some View {
        Button(action: onDeny) {
            Text("Deny").frame(maxWidth: isCompact ? .infinity : nil)
        }
        .buttonStyle(ApprovalButtonStyle(isPrimary: false, minHeight: buttonMinHeight))
        .accessibilityLabel(Text("Deny: \(approval.question)"))
    }

    private var detailsButton: some View {
        Button {
            showsDetails.toggle()
        } label: {
            HStack(spacing: Spacing.xxs) {
                Text("Details")
                Image(systemName: showsDetails ? "chevron.up" : "chevron.down")
                    .imageScale(.small)
                    .accessibilityHidden(true)
            }
            .font(.aicovenBodySmall)
            .foregroundStyle(Color.aicovenTextSecondary)
            .frame(minHeight: buttonMinHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(Text(showsDetails ? "Expanded" : "Collapsed"))
    }

    private func outcomeRow(_ outcome: ToolApprovals.Outcome) -> some View {
        HStack(spacing: Spacing.xs) {
            switch outcome {
            case .approved:
                Image(systemName: "checkmark").foregroundStyle(Color.aicovenTeal)
                Text(outcome.words)
            case .denied:
                Image(systemName: "xmark").foregroundStyle(Color.aicovenTeal)
                Text(outcome.words)
            case .noLongerWaiting:
                Text(outcome.words)
            }
        }
        .font(.aicovenBodySmall.weight(.semibold))
        .foregroundStyle(Color.aicovenTextSecondary)
        .frame(minHeight: buttonMinHeight, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Stone

    /// Elevated fill inside a 1 pt border with a 2 pt bottom edge.
    private var stone: some View {
        RoundedRectangle(cornerRadius: 11)
            .fill(Color.aicovenBorder)
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.aicovenSurfaceElevated)
                    .padding(EdgeInsets(top: 1, leading: 1, bottom: 2, trailing: 1))
            )
    }
}

/// Approve is the stone button fill under the page's colour; Deny is ink
/// inside a 1 pt border. As tall as the platform's controls.
private struct ApprovalButtonStyle: ButtonStyle {
    let isPrimary: Bool
    let minHeight: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.aicovenBodySmall)
            .foregroundStyle(isPrimary ? Color.aicovenSurfaceElevated : Color.aicovenTextPrimary)
            .padding(.horizontal, Spacing.md)
            .frame(minHeight: minHeight)
            .background {
                if isPrimary {
                    RoundedRectangle(cornerRadius: 8).fill(Color.aicovenPurple)
                } else {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(Color.aicovenBorder, lineWidth: 1)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// The spot approvals come to: the one showing now, and "N more waiting"
/// under it. It comes in and leaves slowly, fades under Reduce Motion, and
/// never takes focus.
struct ApprovalSpot: View {
    @ObservedObject var approvals: ToolApprovals
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .trailing, spacing: Spacing.xxs) {
            if let showing = approvals.showing {
                ApprovalBlock(
                    approval: showing.approval,
                    phase: showing.phase,
                    onApprove: { approvals.answer(showing.approval.id, approve: true) },
                    onDeny: { approvals.answer(showing.approval.id, approve: false) }
                )
                .modifier(LeavingSlowly(isLeaving: showing.phase.isLeaving, reduceMotion: reduceMotion))
                .id(showing.approval.id)
                .transition(.asymmetric(insertion: comingIn, removal: .identity))

                if showing.phase == .asking, !approvals.waiting.isEmpty {
                    Button {
                        approvals.showNext()
                    } label: {
                        Text(approvals.waiting.count == 1 ? "1 more waiting" : "\(approvals.waiting.count) more waiting")
                            .font(.aicovenCaption)
                            .foregroundStyle(Color.aicovenTextTertiary)
                        #if os(iOS)
                            .frame(minHeight: 44)
                        #endif
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, Spacing.xxs)
                    .accessibilityHint("Shows the next approval")
                }
            }
        }
        .animation(
            reduceMotion ? .easeOut(duration: 0.5) : .timingCurve(0.2, 0.7, 0.2, 1, duration: 1.1),
            value: approvals.showing?.approval.id
        )
        .onChange(of: approvals.showing?.approval.id, initial: true) { _, showing in
            if let showing {
                approvals.announceShowing(showing)
            }
        }
    }

    private var comingIn: AnyTransition {
        reduceMotion ? .opacity : .opacity.combined(with: .offset(x: 10, y: 14))
    }
}

/// Moves the block out, or fades it under Reduce Motion, once it has said
/// what happened.
private struct LeavingSlowly: ViewModifier {
    let isLeaving: Bool
    let reduceMotion: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isLeaving ? 0 : 1)
            .offset(x: isLeaving && !reduceMotion ? -8 : 0, y: isLeaving && !reduceMotion ? 18 : 0)
            .animation(
                reduceMotion ? .easeIn(duration: 0.4) : .timingCurve(0.5, 0, 0.8, 0.4, duration: ToolApprovals.leavingDuration),
                value: isLeaving
            )
    }
}

private extension ToolApprovals.Phase {
    var isLeaving: Bool {
        if case .leaving = self { return true }
        return false
    }
}
