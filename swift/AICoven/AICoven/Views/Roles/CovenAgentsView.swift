import SwiftUI

/// A coven's agents, as the cloud app lists them: the title and one line,
/// Add first, then one row per agent with its face, name, the first line of
/// its instructions, and the model it runs on. A row opens the agent's form
/// in a sheet.
struct CovenAgentsView: View {
    let coven: Coven
    /// Starts a thread with an agent.
    let onNewThread: (Role) -> Void

    @State private var roles: [Role] = []
    @State private var loadFailed = false
    @State private var adding = false
    @State private var editing: Role?
    /// The agent a delete is asked for; it stays set after the dialog closes,
    /// so the dialog's Delete button still has it.
    @State private var deleting: Role?
    @State private var askingDelete = false
    @State private var deleteFailed = false
    /// The agents whose delete is on its way.
    @State private var deletingIDs: Set<Role.ID> = []

    /// The page's centred column, and its rows.
    private let column: CGFloat = 780
    private let rowHeight: CGFloat = 60

    /// The first line of an agent's instructions that says anything.
    static func instructionsLine(_ instructions: String?) -> String {
        (instructions ?? "")
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? ""
    }

    var body: some View {
        List {
            Group {
                row {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        Text("Agents")
                            .font(.aicovenDisplayLarge)
                            .accessibilityAddTraits(.isHeader)
                        Text("Each agent answers with its own model and instructions.")
                            .font(.aicovenBody)
                            .foregroundStyle(Color.aicovenTextSecondary)
                    }
                    .padding(.top, Spacing.md)
                    .padding(.bottom, Spacing.sm)
                }

                row {
                    Button {
                        AnalyticsService.shared.trackFeatureUsage(featureName: "add_role")
                        adding = true
                    } label: {
                        HStack(spacing: Spacing.sm) {
                            RoundedRectangle(cornerRadius: 11)
                                .strokeBorder(Color.aicovenBorder, style: StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
                                .frame(width: 44, height: 44)
                                .overlay {
                                    Image(systemName: "plus")
                                        .foregroundStyle(Color.aicovenWater)
                                }
                            Text("Add Agent")
                                .font(.title3.weight(.semibold))
                                .foregroundStyle(Color.aicovenWater)
                            Spacer(minLength: 0)
                        }
                        .frame(minHeight: rowHeight)
                        .padding(.horizontal, Spacing.xs)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add Agent")
                }

                ForEach(roles) { role in
                    row {
                        AgentListRow(role: role, rowHeight: rowHeight) { edit(role) }
                    }
                    .accessibilityAction(named: "Delete") { askDelete(role) }
                    .contextMenu {
                        Button("New Thread with \(role.name)") { onNewThread(role) }
                        Button("Edit…") { edit(role) }
                        Button("Delete…", role: .destructive) { askDelete(role) }
                    }
                }

                if loadFailed {
                    row { failureLine("Couldn't load the agents. Open this page again to retry.") }
                } else if deleteFailed {
                    row { failureLine("Couldn't delete the agent. Try again.") }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.aicovenSurface)
        .sheet(isPresented: $adding) {
            ShellFormSheet(onCancel: { adding = false }) {
                AddRoleView(covenId: coven.id, roles: roles) {
                    adding = false
                    Task { await load() }
                }
            }
        }
        .sheet(item: $editing) { role in
            ShellFormSheet(onCancel: { editing = nil }) {
                EditRoleView(roleId: role.id, roles: roles) {
                    editing = nil
                    Task { await load() }
                }
            }
        }
        .confirmationDialog("Delete \(deleting?.name ?? "this agent")?", isPresented: $askingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                if let role = deleting { Task { await delete(role) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its threads keep their replies. \(deleting?.name ?? "This agent") stops answering in \(coven.name).")
        }
        .task(id: coven.id) { await load() }
    }

    /// One row of the list, in the page's centred column with no separator or
    /// background of its own.
    private func row(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .frame(maxWidth: column, alignment: .leading)
            .frame(maxWidth: .infinity)
            .listRowInsets(EdgeInsets(top: 0, leading: Spacing.xl, bottom: 0, trailing: Spacing.xl))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    private func failureLine(_ text: String) -> some View {
        Text(text)
            .font(.aicovenBodySmall)
            .foregroundStyle(Color.aicovenError)
    }

    private func edit(_ role: Role) {
        AnalyticsService.shared.trackRoleView(roleId: role.id)
        editing = role
    }

    private func askDelete(_ role: Role) {
        deleting = role
        askingDelete = true
    }

    /// Reads the coven's agents. Those of another coven (the page moved on
    /// while they were read) are not shown.
    private func load() async {
        let covenID = coven.id
        do {
            let loaded = try await RoleService.shared.loadRoles(covenId: covenID)
            guard covenID == coven.id else { return }
            roles = loaded
            loadFailed = false
        } catch {
            guard covenID == coven.id else { return }
            // The kind of failure only.
            AppErrorReporter.log(message: "Could not read the agents (\(type(of: error)))", context: "CovenAgentsView.load")
            loadFailed = true
        }
    }

    /// Deletes an agent, once: a second ask while the first is on its way
    /// does nothing.
    private func delete(_ role: Role) async {
        guard deletingIDs.insert(role.id).inserted else { return }
        defer { deletingIDs.remove(role.id) }
        do {
            try await RoleService.shared.deleteRole(roleId: role.id)
            AnalyticsService.shared.trackRoleDelete(roleId: role.id)
            deleteFailed = false
        } catch {
            AppErrorReporter.log(message: "Could not delete an agent (\(type(of: error)))", context: "CovenAgentsView.delete")
            deleteFailed = true
        }
        await load()
    }
}

/// One agent: its face, name, the first line of its instructions, and the
/// model it runs on at the right. Under the pointer the row takes the
/// selected fill and shows a chevron.
private struct AgentListRow: View {
    let role: Role
    let rowHeight: CGFloat
    let action: () -> Void
    @State private var hovering = false

    private var instructionsLine: String {
        CovenAgentsView.instructionsLine(role.systemPrompt)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.sm) {
                role.face(size: 44)
                VStack(alignment: .leading, spacing: Spacing.xxxs) {
                    Text(role.name)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(Color.aicovenTextPrimary)
                        .lineLimit(1)
                    if !instructionsLine.isEmpty {
                        Text(instructionsLine)
                            .font(.body)
                            .foregroundStyle(Color.aicovenTextSecondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: Spacing.sm)
                Text(role.model ?? "")
                    .font(.body)
                    .foregroundStyle(Color.aicovenTextTertiary)
                    .lineLimit(1)
                    .fixedSize()
                Image(systemName: "chevron.right")
                    .accessibilityHidden(true)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.aicovenTextTertiary)
                    .opacity(hovering ? 1 : 0)
            }
            .frame(minHeight: rowHeight)
            .padding(.horizontal, Spacing.xs)
            .background(
                RoundedRectangle(cornerRadius: BorderRadius.sm)
                    .fill(hovering ? Color.aicovenSelected : Color.clear)
            )
            .overlay(alignment: .bottom) {
                if !hovering {
                    Rectangle().fill(Color.aicovenRule).frame(height: 1)
                        .padding(.leading, 44 + Spacing.sm + Spacing.xs)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens this agent")
    }
}

/// A form in a sheet over the shell: the form, with Cancel to leave it
/// unsaved. The form closes the sheet itself when it has saved.
struct ShellFormSheet<Content: View>: View {
    let onCancel: () -> Void
    @ViewBuilder let content: () -> Content

    var body: some View {
        NavigationStack {
            content()
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel", action: onCancel)
                    }
                }
        }
        #if os(macOS)
        .frame(minWidth: 620, idealWidth: 720, minHeight: 560, idealHeight: 720)
        #endif
    }
}
