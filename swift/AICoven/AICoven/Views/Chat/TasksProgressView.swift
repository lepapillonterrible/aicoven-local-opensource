import SwiftUI

/// Shows real-time task progress from the agent's scratchpad
struct TasksProgressView: View {
    let tasks: [AgentTask]

    @State private var isExpanded: Bool = true

    private var completedCount: Int {
        tasks.count(where: { $0.completed })
    }

    private var totalCount: Int {
        tasks.count
    }

    var body: some View {
        if !tasks.isEmpty {
            DisclosureGroup(isExpanded: $isExpanded) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(tasks) { task in
                        TaskRow(task: task)
                    }
                }
                .padding(.top, 4)
            } label: {
                HStack(spacing: 6) {
                    Text("📋")
                    Text("Tasks")
                        .font(.system(size: 13, weight: .medium))
                    Text("(\(completedCount)/\(totalCount))")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)

                    // Progress indicator
                    if totalCount > 0 {
                        ProgressView(value: Double(completedCount), total: Double(totalCount))
                            .progressViewStyle(.linear)
                            .frame(width: 60)
                            .tint(completedCount == totalCount ? .green : .aicovenTeal)
                    }
                }
            }
            .tint(.secondary)
        }
    }
}

private struct TaskRow: View {
    let task: AgentTask

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Checkbox icon
            Image(systemName: task.completed ? "checkmark.circle.fill" : "circle")
                .foregroundColor(task.completed ? .green : .secondary)
                .font(.system(size: 14))

            // Task title
            Text(task.title)
                .font(.system(size: 13))
                .foregroundColor(task.completed ? .secondary : .primary)
                .strikethrough(task.completed, color: .secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 2)
        .animation(.easeInOut(duration: 0.2), value: task.completed)
    }
}

#if DEBUG
struct TasksProgressView_Previews: PreviewProvider {
    static var previews: some View {
        VStack(spacing: 20) {
            TasksProgressView(tasks: [
                AgentTask(id: "1", title: "Fetch PolyForm License 1.0.0 text", completed: true),
                AgentTask(id: "2", title: "Determine default branch (dev)", completed: true),
                AgentTask(id: "3", title: "Create LICENSE file in repository", completed: false)
            ])

            TasksProgressView(tasks: [
                AgentTask(id: "1", title: "Search for auth middleware", completed: true),
                AgentTask(id: "2", title: "Read current implementation", completed: false),
                AgentTask(id: "3", title: "Generate updated code", completed: false),
                AgentTask(id: "4", title: "Create pull request", completed: false)
            ])
        }
        .frame(width: 400)
        .padding()
        .background(Color(hex: "#1E1E1E"))
    }
}
#endif
