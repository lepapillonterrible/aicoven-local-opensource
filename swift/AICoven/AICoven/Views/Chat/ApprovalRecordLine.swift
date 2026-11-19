import SwiftUI

/// The line a thread keeps where a turn asked for an approval: "You approved
/// **git push**" or "You denied …", in secondary ink at small size, with no
/// time and no colour.
struct ApprovalRecordLine: View {
    let approval: WorkTrace.Approval

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
            Image(systemName: approval.approved ? "checkmark.circle" : "xmark.circle")
            Text("You \(verb) \(Text(approval.subject).bold())")
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.aicovenBodySmall)
        .foregroundStyle(Color.aicovenTextSecondary)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("You \(verb): \(approval.subject)"))
    }

    private var verb: String {
        approval.approved ? "approved" : "denied"
    }
}
