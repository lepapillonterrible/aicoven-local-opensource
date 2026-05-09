import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// Rich message bubble that renders markdown, attachments, thoughts, and tool calls
struct RichMessageBubble: View {
    let message: EnhancedChatMessage
    var onApproveToolCall: ((String) -> Void)?
    var onRejectToolCall: ((String) -> Void)?

    private var isUser: Bool {
        message.role == "user"
    }

    var body: some View {
        HStack(alignment: .top) {
            if isUser { Spacer(minLength: 0) }

            VStack(alignment: isUser ? .trailing : .leading, spacing: 8) {
                // Header chips
                if !isUser { header }

                // Content (markdown)
                Group {
                    if message.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text("(empty)").foregroundStyle(.secondary)
                    } else {
                        MarkdownView(text: message.content)
                    }
                }
                .padding(16)
                .background(
                    RoundedRectangle(cornerRadius: 12)
                        .fill(isUser ? Color.aicovenPurple : Color.aicovenSurfaceElevated)
                        .shadow(color: Color.black.opacity(0.2), radius: 4, x: 0, y: 2)
                )
                .foregroundStyle(isUser ? Color.white : Color.aicovenTextPrimary)
                // Ensure links and other tappable elements have sufficient contrast
                // against the purple assistant bubble.
                .tint(Color.aicovenTeal)

                // Attachments
                if let atts = message.attachments, !atts.isEmpty {
                    AttachmentsListView(attachments: atts, compact: true)
                }

                // Generated files (e.g., from file.generate)
                if let genFiles = message.generatedFiles, !genFiles.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Generated files")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ForEach(genFiles) { file in
                            HStack(spacing: 8) {
                                Image(systemName: "doc.text")
                                    .foregroundColor(.accentColor)
                                Text(file.name)
                                    .font(.system(size: 13, weight: .medium))
                                    .lineLimit(1)
                                Spacer()
                                if let url = file.url {
                                    Button("Download") {
                                        #if os(macOS)
                                        NSWorkspace.shared.open(url)
                                        #elseif os(iOS)
                                        UIApplication.shared.open(url)
                                        #endif
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        }
                    }
                }

                // Agent features
                if !isUser {
                    AgentFeaturesView(thoughts: message.thoughts, toolCalls: message.toolCalls, onApprove: onApproveToolCall, onReject: onRejectToolCall)
                }

                // Footer (timestamp, tokens)
                footer
            }
            .frame(maxWidth: 800, alignment: isUser ? .trailing : .leading)

            if !isUser { Spacer(minLength: 0) }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Image(systemName: "sparkles")
            // Default to "Strix" for personal threads when no agent role is provided
            Text(message.agentRole ?? "Strix")
            if let model = message.model { Text(model).font(.caption2).padding(.horizontal, 6).padding(.vertical, 2).background(Color.secondary.opacity(0.15)).clipShape(Capsule()) }
        }
        .font(.caption)
        .foregroundStyle(Color.aicovenTeal)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            if let t = message.tokens { Text("\(t) tokens").font(.caption2).foregroundStyle(.secondary) }
            if let d = message.createdAt { Text(d, style: .time).font(.caption2).foregroundStyle(.secondary) }
        }
    }
}

#if DEBUG
struct RichMessageBubble_Previews: PreviewProvider {
    static var previews: some View {
        VStack(alignment: .leading, spacing: 12) {
            RichMessageBubble(message: .init(
                id: "1",
                threadId: "t",
                role: "assistant",
                content: "**Hello** world!\n\n```swift\nprint(\"Hi\")\n```",
                agentRole: "Strix",
                model: "gpt-5.2",
                provider: "openai",
                tokens: 123,
                cost: nil,
                thoughts: ["Searching memory", "Summarizing"],
                toolCalls: [
                    ToolCallDetail(id: "c1", name: "web.search", args: [:] as [String: AnyJSONValue], result: AnyJSONValue("Found results"), error: nil, status: .completed)
                ],
                attachments: [
                    .init(id: "f1", name: "Doc.pdf", mimeType: "application/pdf", sizeBytes: 120000, width: nil, height: nil, url: nil)
                ],
                images: nil,
                generatedFiles: nil,
                createdAt: Date()
            ))
        }
        .padding()
        .frame(width: 640)
    }
}
#endif
