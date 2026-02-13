import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// Shows agent thoughts and tool calls with optional approval actions
struct AgentFeaturesView: View {
    let thoughts: [String]?
    let toolCalls: [ToolCallDetail]?
    var onApprove: ((String) -> Void)?
    var onReject: ((String) -> Void)?

    @State private var showThoughts: Bool = false
    @State private var showToolCalls: Bool = false
    @State private var showPendingToolCalls: Bool = true
    @State private var showCompletedToolCalls: Bool = false

    /// Normalize streaming thoughts into larger chunks so they read as
    /// paragraphs instead of one-word-per-line deltas.
    private var normalizedThoughts: [String] {
        guard let thoughts, !thoughts.isEmpty else { return [] }
        // If we have many very short entries (typical for streaming deltas),
        // collapse them into a single paragraph.
        let averageLength = Double(thoughts.map(\.count).reduce(0, +)) / Double(thoughts.count)
        if thoughts.count > 6, averageLength < 40 {
            let joined = thoughts.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            return joined.isEmpty ? thoughts : [joined]
        }
        return thoughts
    }

    private var pendingToolCalls: [ToolCallDetail] {
        (toolCalls ?? []).filter { $0.status == .pending }
    }

    private var completedToolCalls: [ToolCallDetail] {
        (toolCalls ?? []).filter { $0.status != .pending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Collapsible thoughts section
            if !normalizedThoughts.isEmpty {
                DisclosureGroup(isExpanded: $showThoughts) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(normalizedThoughts.enumerated()), id: \.offset) { _, thought in
                            Text(thought)
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    HStack(spacing: 6) {
                        Text("💭")
                        Text("Reasoning")
                            .font(.system(size: 13, weight: .medium))
                    }
                }
                .tint(.secondary)
            }

            // Collapsible tool calls section
            if let toolCalls, !toolCalls.isEmpty {
                DisclosureGroup(isExpanded: $showToolCalls) {
                    VStack(alignment: .leading, spacing: 8) {
                        if !pendingToolCalls.isEmpty {
                            DisclosureGroup(isExpanded: $showPendingToolCalls) {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(pendingToolCalls, id: \.id) { call in
                                        ToolCallCard(call: call, onApprove: onApprove, onReject: onReject)
                                    }
                                }
                                .padding(.top, 4)
                            } label: {
                                HStack(spacing: 6) {
                                    Text("Pending")
                                        .font(.system(size: 12, weight: .medium))
                                    Text("(\(pendingToolCalls.count))")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                }
                            }
                            .tint(.secondary)
                        }

                        if !completedToolCalls.isEmpty {
                            DisclosureGroup(isExpanded: $showCompletedToolCalls) {
                                VStack(alignment: .leading, spacing: 8) {
                                    ForEach(completedToolCalls, id: \.id) { call in
                                        ToolCallCard(call: call, onApprove: onApprove, onReject: onReject)
                                    }
                                }
                                .padding(.top, 4)
                            } label: {
                                HStack(spacing: 6) {
                                    Text("History")
                                        .font(.system(size: 12, weight: .medium))
                                    Text("(\(completedToolCalls.count))")
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                }
                            }
                            .tint(.secondary)
                        }
                    }
                    .padding(.top, 4)
                } label: {
                    HStack(spacing: 6) {
                        Text("🔧")
                        Text("Tool Calls")
                            .font(.system(size: 13, weight: .medium))
                        if toolCalls.count > 1 {
                            Text("(\(toolCalls.count))")
                                .font(.system(size: 11))
                                .foregroundColor(.secondary)
                        }
                    }
                }
                .tint(.secondary)
            }
        }
    }
}

private struct ToolCallCard: View {
    let call: ToolCallDetail
    var onApprove: ((String) -> Void)?
    var onReject: ((String) -> Void)?

    /// Helper to convert AnyJSONValue to plain Swift types
    private func unwrapAnyJSON(_ value: Any) -> Any {
        if let wrapped = value as? AnyJSONValue {
            return unwrapAnyJSON(wrapped.value)
        }
        if let dict = value as? [String: AnyJSONValue] {
            return dict.mapValues { unwrapAnyJSON($0.value) }
        }
        if let array = value as? [AnyJSONValue] {
            return array.map { unwrapAnyJSON($0.value) }
        }
        return value
    }

    /// Helper to format result as text (handles dict, string, or other types)
    private func formatResultText(_ result: AnyJSONValue) -> String {
        let unwrapped = unwrapAnyJSON(result.value)

        // If it's a string, return it directly
        if let str = unwrapped as? String {
            return str
        }
        // If it's a dict, try to get "output" or convert to JSON
        if let dict = unwrapped as? [String: Any] {
            if let output = dict["output"] as? String {
                return output
            }
            // Otherwise show pretty JSON (truncated)
            if let data = try? JSONSerialization.data(withJSONObject: dict, options: .prettyPrinted),
               let json = String(data: data, encoding: .utf8) {
                return json.prefix(500) + (json.count > 500 ? "..." : "")
            }
        }
        // Fallback: show string representation
        return String(describing: unwrapped)
    }

    /// Helper to format args dictionary as compact JSON
    private func formatArgsText(_ args: [String: AnyJSONValue]) -> String {
        let plain = args.mapValues { unwrapAnyJSON($0.value) }
        if JSONSerialization.isValidJSONObject(plain),
           let data = try? JSONSerialization.data(withJSONObject: plain, options: .prettyPrinted),
           let json = String(data: data, encoding: .utf8) {
            return json.prefix(500) + (json.count > 500 ? "..." : "")
        }
        return String(describing: plain)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(call.name)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                StatusPill(status: call.status)
            }
            .frame(maxWidth: .infinity)

            // Args
            if !call.args.isEmpty {
                let argsText = formatArgsText(call.args)
                if !argsText.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Args")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                        Text(argsText)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            // Display result if available (handle dict or string). For file
            // generation tools, surface a more actionable "Generated file"
            // card with an optional Open button when a URL is present.
            if let result = call.result {
                let unwrapped = unwrapAnyJSON(result.value)

                if call.name.hasPrefix("file.generate"), let dict = unwrapped as? [String: Any] {
                    let filename = (dict["filename"] as? String) ?? "Generated file"
                    let fileURLString =
                        (dict["file_url"] as? String)
                            ?? (dict["url"] as? String)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Generated file")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(.secondary)
                        HStack(spacing: 8) {
                            Image(systemName: "doc.text")
                                .foregroundColor(.accentColor)
                            Text(filename)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                            Spacer()
                            #if os(macOS)
                            if let fileURLString,
                               let url = URL(string: fileURLString) {
                                Button("Open") {
                                    NSWorkspace.shared.open(url)
                                }
                                .buttonStyle(.bordered)
                            }
                            #elseif os(iOS)
                            if let fileURLString,
                               let url = URL(string: fileURLString) {
                                Button("Open") {
                                    UIApplication.shared.open(url)
                                }
                                .buttonStyle(.bordered)
                            }
                            #endif
                        }
                    }
                } else {
                    let resultText = formatResultText(result)
                    if !resultText.isEmpty {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Result")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.secondary)
                            Text(resultText)
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }

            // Error, if any
            if let error = call.error, !error.isEmpty {
                Text(error)
                    .font(.system(size: 11))
                    .foregroundColor(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if call.status == .pending {
                HStack(spacing: 8) {
                    Button("Approve") { onApprove?(call.id) }
                        .buttonStyle(.borderedProminent)
                    Button("Reject") { onReject?(call.id) }
                        .buttonStyle(.bordered)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.15))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

private struct StatusPill: View {
    let status: ToolCallDetail.Status
    var body: some View {
        Text(status.rawValue.capitalized)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(background)
            .foregroundStyle(.white)
            .clipShape(Capsule())
    }

    private var background: Color {
        switch status {
        case .pending: .orange
        case .approved: .blue
        case .rejected: .red
        case .completed: .green
        case .failed: .gray
        }
    }
}

#if DEBUG
struct AgentFeaturesView_Previews: PreviewProvider {
    static var previews: some View {
        AgentFeaturesView(
            thoughts: ["Thinking about retrieving relevant files...", "Selecting the best model..."],
            toolCalls: [
                .init(id: "1", name: "web.search", args: [:], result: AnyJSONValue("Found 3 results"), error: nil, status: .completed),
                .init(id: "2", name: "github.create_pr", args: [:], result: nil, error: nil, status: .pending)
            ]
        )
        .frame(width: 520)
        .padding()
    }
}
#endif
