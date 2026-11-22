import SwiftUI

/// A coven's agents, as the cloud app lists them: the title and one line,
/// Add first, then one row per agent with its face, name, the first line of
/// its instructions, and the model and connection it runs on. A row opens
/// the agent's form in a sheet. The list is laid out for the Mac, the iPad
/// and the iPhone (`AgentListLayout`).
struct CovenAgentsView: View {
    let coven: Coven
    /// Starts a thread with an agent.
    let onNewThread: (Role) -> Void

    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.isPadLayout) private var isPadLayout
    /// The person's connections and their models, for the rows' model lines.
    @StateObject private var choices = AgentModelChoices()
    @State private var roles: [Role] = []
    @State private var loadFailed = false
    /// The agent form on screen, if one is: each showing is its own.
    @State private var form: AgentForm?
    @State private var isOnScreen = false
    /// Counts the readings of the agents, so that only the latest is shown.
    @State private var readings = 0
    /// The agent a delete is asked for; it stays set after the dialog closes,
    /// so the dialog's Delete button still has it.
    @State private var deleting: Role?
    @State private var askingDelete = false
    @State private var deleteFailed = false
    /// The agents whose delete is on its way.
    @State private var deletingIDs: Set<Role.ID> = []

    static let loadFailure = "Couldn't load the agents. Open this page again to retry."
    static let deleteFailure = "Couldn't delete the agent. Try again."

    private var layout: AgentListLayout {
        .current(isPadLayout: isPadLayout)
    }

    /// The first line of an agent's instructions that says anything.
    static func instructionsLine(_ instructions: String?) -> String {
        var first = ""
        // Read a line at a time, and no further than the first that says something.
        instructions?.enumerateLines { line, stop in
            let said = line.trimmingCharacters(in: .whitespaces)
            if !said.isEmpty {
                first = said
                stop = true
            }
        }
        return first
    }

    var body: some View {
        List {
            Group {
                row {
                    VStack(alignment: .leading, spacing: Spacing.xs) {
                        // At compact width (the iPhone) the bar names the
                        // page, so the title is drawn once.
                        if horizontalSizeClass != .compact {
                            Text("Agents")
                                .font(.aicovenDisplayLarge)
                                .accessibilityAddTraits(.isHeader)
                        }
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
                        form = .add(showing: UUID())
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
                                .font(layout.nameFont)
                                .foregroundStyle(Color.aicovenWater)
                            Spacer(minLength: 0)
                        }
                        .frame(minHeight: layout.rowHeight)
                        .padding(.horizontal, layout.rowPadding)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add Agent")
                }

                ForEach(roles) { role in
                    row {
                        // The form records the view of the agent itself.
                        AgentListRow(role: role, modelLine: choices.runsOnLine(for: role), layout: layout) {
                            form = .edit(role, showing: UUID())
                        }
                    }
                    .accessibilityAction(named: "Delete") { askDelete(role) }
                    .contextMenu {
                        Button("New Thread with \(role.name)") { onNewThread(role) }
                        Button("Edit…") { form = .edit(role, showing: UUID()) }
                        Button("Delete…", role: .destructive) { askDelete(role) }
                    }
                    .swipeActions(edge: .trailing) {
                        Button("Delete", role: .destructive) { askDelete(role) }
                    }
                }

                if loadFailed {
                    row { failureLine(Self.loadFailure) }
                } else if deleteFailed {
                    row { failureLine(Self.deleteFailure) }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.aicovenSurface)
        .sheet(item: $form) { shown in
            let agentForm = AgentFormView(
                mode: shown.role.map { .edit(roleId: $0.id) } ?? .add(covenId: coven.id),
                covenName: coven.name,
                onCancel: { if form == shown { form = nil } },
                onFinished: { completed(shown) }
            )
            // On the Mac the form is the sheet, with its own bars; elsewhere
            // it is a page with Cancel and Save in a navigation bar.
            #if os(macOS)
            agentForm
            #else
            NavigationStack { agentForm }
            #endif
        }
        .confirmationDialog("Delete \(deleting?.name ?? "this agent")?", isPresented: $askingDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                // For the account that said so: read here, not when the
                // delete's turn comes.
                let account = UserScope.currentUserID
                if let role = deleting { Task { await delete(role, as: account) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Its threads keep their replies. \(deleting?.name ?? "This agent") stops answering in \(coven.name).")
        }
        .task(id: coven.id) { await load() }
        .onAppear { isOnScreen = true }
        .onDisappear { isOnScreen = false }
    }

    /// One row of the list, in the page's centred column with no separator or
    /// background of its own.
    private func row(@ViewBuilder _ content: () -> some View) -> some View {
        // The phone's layout has no column: a row fills the width, from
        // its leading edge.
        content()
            .frame(maxWidth: layout.column ?? .infinity, alignment: .leading)
            .frame(maxWidth: .infinity)
            .listRowInsets(EdgeInsets(top: 0, leading: layout.pageInset, bottom: 0, trailing: layout.pageInset))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    private func failureLine(_ text: String) -> some View {
        Text(text)
            .font(.aicovenBodySmall)
            .foregroundStyle(Color.aicovenError)
    }

    /// A form has saved (or deleted its agent): its sheet closes, if it is
    /// still the one on screen (a save can end after its sheet was cancelled
    /// and another opened), and the agents are read again either way.
    private func completed(_ shown: AgentForm) {
        if form == shown { form = nil }
        // Something was done since a delete failed: that is no longer what to say.
        deleteFailed = false
        Task { await load() }
    }

    /// Says a failure to VoiceOver, as well as where it shows: only while
    /// this page is on screen, not for one the person has left.
    private func failed(_ text: String) {
        guard isOnScreen else { return }
        AccessibilityNotification.Announcement(text).post()
    }

    private func askDelete(_ role: Role) {
        deleting = role
        askingDelete = true
    }

    /// Reads the coven's agents. The page is one coven's (it is made anew
    /// for another), so what is read is this coven's.
    private func load() async {
        // Only the latest reading is shown: one begun before a save or a
        // delete can land after the one begun for it.
        readings += 1
        let reading = readings
        do {
            let loaded = try await RoleService.shared.loadRoles(covenId: coven.id)
            guard reading == readings else { return }
            roles = loaded
            loadFailed = false
            await choices.loadModelNames(for: loaded)
        } catch {
            guard reading == readings else { return }
            // The kind of failure only.
            AppErrorReporter.log(message: "Could not read the agents (\(type(of: error)))", context: "CovenAgentsView.load")
            loadFailed = true
            failed(Self.loadFailure)
        }
    }

    /// Deletes an agent, once: a second ask while the first is on its way
    /// does nothing.
    private func delete(_ role: Role, as account: String) async {
        guard deletingIDs.insert(role.id).inserted else { return }
        defer { deletingIDs.remove(role.id) }
        do {
            try await RoleService.shared.deleteRole(roleId: role.id, as: account)
            AnalyticsService.shared.trackRoleDelete(roleId: role.id)
            deleteFailed = false
        } catch {
            AppErrorReporter.log(message: "Could not delete an agent (\(type(of: error)))", context: "CovenAgentsView.delete")
            deleteFailed = true
            failed(Self.deleteFailure)
        }
        await load()
    }
}

/// How the list lays out on each platform: the Mac's 780 pt column with 60 pt
/// rows, the iPad layout's 700 pt column with 68 pt rows and 17 pt names, and
/// the phone layout's full width with 64 pt rows.
enum AgentListLayout {
    case mac, pad, phone

    static func current(isPadLayout: Bool) -> AgentListLayout {
        #if os(macOS)
        return .mac
        #else
        return isPadLayout ? .pad : .phone
        #endif
    }

    var column: CGFloat? {
        switch self {
        case .mac: 780
        case .pad: 700
        case .phone: nil
        }
    }

    var rowHeight: CGFloat {
        switch self {
        case .mac: 60
        case .pad: 68
        case .phone: 64
        }
    }

    var pageInset: CGFloat {
        self == .phone ? Spacing.md : Spacing.xl
    }

    /// The row's own padding, so a highlight reaches past its text.
    var rowPadding: CGFloat {
        self == .phone ? 0 : Spacing.xs
    }

    /// Text styles, so the rows follow the person's text size: 15 pt on the
    /// Mac (title 3) and 17 pt on touch (headline) at the default size.
    var nameFont: Font {
        self == .mac ? .title3.weight(.semibold) : .headline
    }

    /// The instructions line and the model: 13 pt on the Mac (body) and 15 pt
    /// on touch (subheadline).
    var secondaryFont: Font {
        self == .mac ? .body : .subheadline
    }
}

/// One agent: its face, name, the first line of its instructions, and the
/// model it runs on. The model is at the right, or on the name's line on the
/// iPhone. Under the pointer the row takes the selected fill and shows a
/// chevron.
private struct AgentListRow: View {
    let role: Role
    let modelLine: String
    let layout: AgentListLayout
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Spacing.sm) {
                role.face(size: 44)
                if layout == .phone {
                    stacked
                } else {
                    // A narrow pane (an iPad in portrait beside the sidebar)
                    // takes the stacked row, so the instructions keep the
                    // row's width.
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: Spacing.sm) {
                            VStack(alignment: .leading, spacing: Spacing.xxxs) {
                                nameText
                                instructionsText
                                    .frame(minWidth: 0, idealWidth: 200, alignment: .leading)
                            }
                            Spacer(minLength: Spacing.sm)
                            modelText
                                .fixedSize()
                            Image(systemName: "chevron.right")
                                .accessibilityHidden(true)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.aicovenTextTertiary)
                                .opacity(hovering ? 1 : 0)
                        }
                        stacked
                    }
                }
            }
            .frame(minHeight: layout.rowHeight)
            .padding(.horizontal, layout.rowPadding)
            .background(
                RoundedRectangle(cornerRadius: BorderRadius.sm)
                    .fill(hovering ? Color.aicovenSelected : Color.clear)
            )
            .overlay(alignment: .bottom) {
                if !hovering {
                    Rectangle().fill(Color.aicovenRule).frame(height: 1)
                        .padding(.leading, 44 + Spacing.sm + layout.rowPadding)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens this agent")
    }

    private var nameText: some View {
        Text(role.name)
            .font(layout.nameFont)
            .foregroundStyle(Color.aicovenTextPrimary)
            .lineLimit(1)
    }

    /// The name with the model at its right, and the instructions under them.
    private var stacked: some View {
        VStack(alignment: .leading, spacing: Spacing.xxxs) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                nameText
                Spacer(minLength: Spacing.xs)
                modelText
            }
            instructionsText
        }
    }

    @ViewBuilder
    private var instructionsText: some View {
        let line = CovenAgentsView.instructionsLine(role.systemPrompt)
        if !line.isEmpty {
            Text(line)
                .font(layout.secondaryFont)
                .foregroundStyle(Color.aicovenTextSecondary)
                .lineLimit(1)
        }
    }

    private var modelText: some View {
        Text(modelLine)
            .font(layout.secondaryFont)
            .foregroundStyle(Color.aicovenTextTertiary)
            .lineLimit(1)
    }
}

/// One showing of an agent's form: a new agent, or one being edited. Each
/// showing is its own, so a form that saves late closes only its own sheet.
enum AgentForm: Identifiable, Equatable {
    case add(showing: UUID)
    case edit(Role, showing: UUID)

    var id: UUID {
        switch self {
        case let .add(showing), let .edit(_, showing): showing
        }
    }

    /// The agent being edited; nil for a new one.
    var role: Role? {
        if case let .edit(role, _) = self { return role }
        return nil
    }

    static func == (one: AgentForm, other: AgentForm) -> Bool {
        one.id == other.id
    }
}
