import SwiftUI

/// Which work trace Details shows: the running turn's in a thread, which
/// updates as it works, or a finished turn's.
enum WorkTraceTarget: Identifiable, Equatable {
    case running(threadID: String)
    case finished(messageID: String, trace: WorkTrace)

    var id: String {
        switch self {
        case let .running(threadID): "running:\(threadID)"
        case let .finished(messageID, _): "finished:\(messageID)"
        }
    }
}

/// The work trace: the steps behind one answer with their times, and the
/// reasoning the turn reported. In a sheet, with Done.
struct WorkTraceSheet: View {
    let target: WorkTraceTarget
    @ObservedObject private var turns = TurnEngine.shared
    @Environment(\.dismiss) private var dismiss

    /// The trace to show. A running turn that ends while Details is open
    /// leaves its finished trace here.
    private var trace: WorkTrace? {
        switch target {
        case let .running(threadID): turns.running[threadID]?.trace ?? turns.endings[threadID]?.trace
        case let .finished(_, trace): trace
        }
    }

    var body: some View {
        NavigationStack {
            WorkTraceView(trace: trace)
                .navigationTitle("Details")
            #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
            #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .themedColorScheme()
        #if os(macOS)
            .frame(minWidth: 420, idealWidth: 480, minHeight: 320, idealHeight: 460)
        #endif
    }
}

struct WorkTraceView: View {
    let trace: WorkTrace?

    var body: some View {
        List {
            Group {
                if let trace, !trace.isEmpty {
                    if !trace.steps.isEmpty {
                        Section("Steps") {
                            // Row ids are unique across sections: a List
                            // reuses a row whose id repeats in another one.
                            ForEach(trace.steps) { step in
                                stepRow(step, in: trace)
                                    .id("step-\(step.id)")
                            }
                        }
                    }
                    if !trace.reasoning.isEmpty {
                        Section("Reasoning") {
                            ForEach(Array(trace.reasoning.enumerated()), id: \.offset) { offset, line in
                                Text(line)
                                    .font(.aicovenBodySmall)
                                    .foregroundStyle(Color.aicovenTextSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .id("reasoning-\(offset)")
                            }
                        }
                    }
                } else {
                    Text(trace?.finishedAt == nil ? "Nothing to show yet." : "No steps were recorded.")
                        .font(.aicovenBodySmall)
                        .foregroundStyle(Color.aicovenTextSecondary)
                }
            }
            .listRowBackground(Color.aicovenSurfaceElevated)
        }
        .scrollContentBackground(.hidden)
        .background(Color.aicovenSurface)
        .safeAreaInset(edge: .top, spacing: 0) {
            Text(subtitle)
                .font(.aicovenBodySmall)
                .foregroundStyle(Color.aicovenTextSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.xs)
        }
    }

    private var subtitle: String {
        guard let trace else { return "Nothing to show yet." }
        guard let finishedAt = trace.finishedAt else { return "Not finished · updates live" }
        return "Worked \(WorkTrace.durationWords(finishedAt.timeIntervalSince(trace.startedAt)))"
    }

    private func stepRow(_ step: WorkTrace.Step, in trace: WorkTrace) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
            Text(WorkTrace.clock(step.startedAt.timeIntervalSince(trace.startedAt)))
                .font(.aicovenBodySmall)
                .monospacedDigit()
                .foregroundStyle(Color.aicovenTextTertiary)
                .frame(minWidth: 36, alignment: .leading)
            VStack(alignment: .leading, spacing: Spacing.xxxs) {
                Text(Self.kindLabel(step, turnFinished: trace.finishedAt != nil))
                    .font(.aicovenCaption)
                    .foregroundStyle(step.failed ? Color.aicovenError : Color.aicovenTextSecondary)
                Text(step.tool)
                    .font(.aicovenBody)
                    .foregroundStyle(Color.aicovenTextPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// "Tool · 3 seconds", "Tool · failed · 3 seconds", "Tool · running", or
    /// "Tool · not finished" for one still running when its turn ended.
    static func kindLabel(_ step: WorkTrace.Step, turnFinished: Bool) -> String {
        guard let finishedAt = step.finishedAt else {
            return turnFinished ? "Tool · not finished" : "Tool · running"
        }
        let duration = WorkTrace.durationWords(finishedAt.timeIntervalSince(step.startedAt))
        return step.failed ? "Tool · failed · \(duration)" : "Tool · \(duration)"
    }
}
