import SwiftUI

/// SwiftUI view for approving/denying shell command execution.
/// Displays command details, risk level, and approval options.
struct ShellApprovalView: View {
    /// The approval request to display
    let request: ShellApprovalRequest

    /// Callback when user makes a decision
    let onDecision: (ShellApprovalDecision) -> Void

    // State for "always approve" pattern input
    @State private var showAlwaysApprove = false
    @State private var customPattern = ""

    var body: some View {
        VStack(spacing: 20) {
            // Header with risk indicator
            headerSection

            // Command display
            commandSection

            // Working directory if present
            if let workingDir = request.workingDir {
                workingDirSection(workingDir)
            }

            // Risk explanation
            riskExplanationSection

            // Always approve option (expandable)
            if showAlwaysApprove {
                alwaysApproveSection
            }

            Spacer()

            // Action buttons
            buttonSection
        }
        .padding(24)
        .frame(minWidth: 400, minHeight: 350)
        #if os(macOS)
            .background(Color(NSColor.windowBackgroundColor))
        #else
            .background(Color(UIColor.systemBackground))
        #endif
    }

    // MARK: - View Components

    /// Header section with title and risk badge
    private var headerSection: some View {
        HStack {
            // Shield icon colored by risk level
            Image(systemName: riskIcon)
                .font(.system(size: 28))
                .foregroundColor(riskColor)

            VStack(alignment: .leading, spacing: 4) {
                Text("Shell Command Approval")
                    .font(.headline)

                Text("An agent wants to run a command on your system")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }

            Spacer()

            // Risk level badge
            Text(request.riskLevel.rawValue.uppercased())
                .font(.caption)
                .fontWeight(.bold)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(riskColor.opacity(0.2))
                .foregroundColor(riskColor)
                .cornerRadius(4)
        }
    }

    /// Command display section with monospace formatting
    private var commandSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Command")
                .font(.caption)
                .foregroundColor(.secondary)

            ScrollView(.horizontal, showsIndicators: true) {
                Text(request.command)
                    .font(.system(.body, design: .monospaced))
                    .padding(12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            #if os(macOS)
                .background(Color(NSColor.textBackgroundColor).opacity(0.5))
            #else
                .background(Color(UIColor.secondarySystemBackground))
            #endif
                .cornerRadius(8)
        }
    }

    /// Working directory section
    private func workingDirSection(_ dir: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Working Directory")
                .font(.caption)
                .foregroundColor(.secondary)

            Text(dir)
                .font(.system(.caption, design: .monospaced))
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Risk explanation based on level
    private var riskExplanationSection: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "info.circle")
                .foregroundColor(.blue)

            Text(riskExplanation)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        #if os(macOS)
            .background(Color(NSColor.controlBackgroundColor))
        #else
            .background(Color(UIColor.tertiarySystemBackground))
        #endif
            .cornerRadius(8)
    }

    /// "Always approve" pattern input section
    private var alwaysApproveSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Auto-approve pattern (regex)")
                .font(.caption)
                .foregroundColor(.secondary)

            TextField("e.g. ^ls\\b or ^git status", text: $customPattern)
                .textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced))

            Text("Commands matching this pattern will be approved automatically in the future.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(12)
        #if os(macOS)
            .background(Color(NSColor.controlBackgroundColor))
        #else
            .background(Color(UIColor.tertiarySystemBackground))
        #endif
            .cornerRadius(8)
    }

    /// Action buttons section
    private var buttonSection: some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                // Deny button
                Button(action: { onDecision(.deny(reason: "User denied")) }) {
                    HStack {
                        Image(systemName: "xmark.circle")
                        Text("Deny")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
                .tint(.red)

                // Approve button
                Button(action: { onDecision(.approve) }) {
                    HStack {
                        Image(systemName: "checkmark.circle")
                        Text("Approve Once")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(.green)
            }

            // Always approve toggle/button
            if showAlwaysApprove, !customPattern.isEmpty {
                Button(action: {
                    onDecision(.approveAlways(pattern: customPattern))
                }) {
                    HStack {
                        Image(systemName: "checkmark.circle.badge.checkmark")
                        Text("Always Approve Pattern")
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                }
                .buttonStyle(.bordered)
                .tint(.blue)
            } else {
                Button(action: {
                    // Generate a default pattern from the command
                    let firstWord = request.command.split(separator: " ").first.map(String.init) ?? request.command
                    let escaped = NSRegularExpression.escapedPattern(for: firstWord)
                    customPattern = #"^"# + escaped + #"\b"#
                    showAlwaysApprove = true
                }) {
                    Text("Always approve similar commands...")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .foregroundColor(.blue)
            }
        }
    }

    // MARK: - Computed Properties

    /// Icon for the risk level
    private var riskIcon: String {
        switch request.riskLevel {
        case .low:
            "shield.checkmark"
        case .medium:
            "shield.lefthalf.filled"
        case .high:
            "exclamationmark.shield"
        }
    }

    /// Color for the risk level
    private var riskColor: Color {
        switch request.riskLevel {
        case .low:
            .green
        case .medium:
            .yellow
        case .high:
            .red
        }
    }

    /// Explanation text for each risk level
    private var riskExplanation: String {
        switch request.riskLevel {
        case .low:
            "This command appears to be read-only and safe. It should not modify any files or system settings."
        case .medium:
            "This command may modify files or settings. Review it carefully before approving."
        case .high:
            "⚠️ This command is potentially dangerous and could cause system damage or data loss. Proceed with extreme caution."
        }
    }
}

// MARK: - Preview

#if DEBUG
struct ShellApprovalView_Previews: PreviewProvider {
    static var previews: some View {
        // Preview with a sample request
        // Note: In preview, we can't use the real ShellApprovalRequest because it contains a continuation.
        // This preview is for visual testing only.
        Text("ShellApprovalView preview requires a mock request")
            .padding()
    }
}
#endif
