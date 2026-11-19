import SwiftUI

/// A message waiting for the running turn: a dashed bubble at the person's
/// side of the thread, with when it goes, Edit, which takes it back into the
/// field, and Remove.
struct WaitingMessageBubble: View {
    let message: TurnEngine.WaitingMessage
    /// First in line: it goes when the running turn finishes.
    let isNext: Bool
    let agentName: String
    let onEdit: () -> Void
    let onRemove: () -> Void

    /// What the line under the bubble says.
    nonisolated static func note(isNext: Bool, agentName: String) -> String {
        isNext ? "Waiting. Sends when \(agentName) finishes." : "Waiting. Sends after the one above."
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: Spacing.xxs) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(message.userText)
                    .font(.aicovenBody)
                    .foregroundStyle(Color.aicovenTextSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if !message.attachments.isEmpty {
                    AttachmentsListView(attachments: message.attachments, compact: true)
                }
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.aicovenBorder, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
            )
            // As wide as its text, up to most of the reading column.
            .frame(maxWidth: 560, alignment: .trailing)
            HStack(spacing: Spacing.sm) {
                Text(Self.note(isNext: isNext, agentName: agentName))
                    .foregroundStyle(Color.aicovenTextTertiary)
                Button("Edit", action: onEdit)
                    .buttonStyle(.textLink)
                    .accessibilityHint("Takes this message back into the composer")
                Button("Remove", action: onRemove)
                    .buttonStyle(.textLink)
                    .accessibilityHint("Deletes this waiting message")
            }
            .font(.aicovenBodySmall)
        }
        .frame(maxWidth: 800, alignment: .trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("waiting-message")
    }
}
