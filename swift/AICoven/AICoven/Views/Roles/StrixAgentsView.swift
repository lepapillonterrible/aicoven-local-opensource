import SwiftUI

/// Strix's Agents page: Strix itself, as a coven's agents are listed. Strix
/// is no coven's agent here, so no agent is added beside it; its row opens
/// it in the agent form.
struct StrixAgentsView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.isPadLayout) private var isPadLayout
    @StateObject private var choices = AgentModelChoices()
    /// Strix as a row shows it; nil until its settings are read.
    @State private var strix: Role?
    @State private var loadFailed = false
    /// The showing of the form on screen, if one is: each is its own, so
    /// one that saves late closes only its own sheet.
    @State private var form: Showing?
    /// Counts the readings, so that only the latest is shown.
    @State private var readings = 0
    @State private var isOnScreen = false

    static let loadFailure = "Couldn't load Strix. Open this page again to retry."

    private var layout: AgentListLayout {
        .current(isPadLayout: isPadLayout)
    }

    /// What the row says Strix runs on while it runs on nothing, as the form says it.
    static let noConnection = "No AI connection yet"

    /// Strix as a list's row shows an agent, from its settings. Where no
    /// connection is stored with it, it is the first of its provider's
    /// among the person's `connections`, as its form takes it.
    static func row(for settings: LocalStrixSettings, among connections: [ProviderAccount] = []) -> Role {
        let provider = settings.provider?.lowercased()
        let connection = settings.providerAccountId ?? connections.first { $0.provider.lowercased() == provider }?.id
        return Role(
            id: "strix", covenId: "", name: "Strix", emoji: nil, description: nil, systemPrompt: settings.systemPrompt,
            model: settings.model, provider: settings.provider, providerAccountId: connection,
            temperature: settings.temperature, maxTokens: settings.maxTokens,
            settings: RoleSettings(
                toolConfig: nil, allowedTools: nil, collaboratorRoleIds: nil, autonomousMode: nil,
                autonomousMaxSteps: settings.autonomousMaxSteps, plannerMaxTasks: nil, plannerMaxSeconds: nil, iconSymbol: "sparkles"
            ),
            createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0)
        )
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
                if let strix {
                    row {
                        let runsOn = choices.runsOnLine(for: strix)
                        AgentListRow(role: strix, modelLine: runsOn.isEmpty ? Self.noConnection : runsOn, layout: layout) { form = Showing() }
                    }
                }
                if loadFailed {
                    row {
                        Text(Self.loadFailure)
                            .font(.aicovenBodySmall)
                            .foregroundStyle(Color.aicovenError)
                    }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.aicovenSurface)
        .sheet(item: $form) { shown in
            let strixForm = AgentFormView(
                mode: .strix,
                covenName: "Strix",
                onCancel: { if form?.id == shown.id { form = nil } },
                onFinished: {
                    if form?.id == shown.id { form = nil }
                    Task { await load() }
                }
            )
            #if os(macOS)
            strixForm
            #else
            NavigationStack { strixForm }
            #endif
        }
        .task { await load() }
        .onAppear { isOnScreen = true }
        .onDisappear { isOnScreen = false }
    }

    /// One row of the list, in the page's column, as the agents' list has it.
    private func row(@ViewBuilder _ content: () -> some View) -> some View {
        content()
            .frame(maxWidth: layout.column ?? .infinity, alignment: .leading)
            .frame(maxWidth: .infinity)
            .listRowInsets(EdgeInsets(top: 0, leading: layout.pageInset, bottom: 0, trailing: layout.pageInset))
            .listRowSeparator(.hidden)
            .listRowBackground(Color.clear)
    }

    /// Reads Strix's settings, as the account signed in when it is asked.
    private func load() async {
        readings += 1
        let reading = readings
        let account = UserScope.currentUserID
        do {
            let settings = try await StrixSettingsService.shared.loadPersonalStrix()
            // Only the latest reading, and only for the account it was read for.
            guard reading == readings, UserScope.currentUserID == account else { return }
            strix = Self.row(for: settings)
            loadFailed = false
            // With the connections read, the one Strix runs on is known
            // where none is stored with it, and its models name its model.
            guard await (try? choices.loadAccounts()) != nil, reading == readings, UserScope.currentUserID == account else { return }
            let row = Self.row(for: settings, among: choices.accounts)
            strix = row
            await choices.loadModelNames(for: [row])
        } catch {
            guard reading == readings else { return }
            // The kind of failure only.
            AppErrorReporter.log(message: "Could not read Strix's settings (\(type(of: error)))", context: "StrixAgentsView.load")
            loadFailed = true
            if isOnScreen { AccessibilityNotification.Announcement(Self.loadFailure).post() }
        }
    }
}

/// One showing of Strix's form.
private struct Showing: Identifiable {
    let id = UUID()
}
