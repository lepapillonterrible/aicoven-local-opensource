internal import Combine
import SwiftUI

/// What the Connections screen of a coven shows and changes: which of the
/// person's connected apps and MCP servers the coven's agents may use, and
/// whether to read only or to make changes too.
@MainActor
final class CovenConnectionsModel: ObservableObject {
    /// A connected app, as a row shows it.
    struct App: Identifiable, Equatable {
        let id: String
        let name: String
        /// The account connected for it, or nil if there is none.
        let account: String?
    }

    /// An MCP server, as a row shows it.
    struct Server: Identifiable, Equatable {
        let id: String
        let name: String
        /// "3 tools", or that it cannot be reached.
        let line: String
        let cannotConnect: Bool
        /// Whether it marks any tool as read-only: one that marks none
        /// offers nothing when it is on to read.
        let marksReadOnlyTools: Bool
    }

    /// What the screen needs of the world, so tests can stand in for it.
    struct Sources {
        var choice: @Sendable (_ covenID: String) async throws -> CovenConnections?
        var apps: @Sendable () async -> [App]
        var servers: @Sendable () async -> [Server]
        var save: @Sendable (_ choice: CovenConnections, _ covenID: String) async throws -> Void

        static let live = Sources(
            choice: { covenID in
                let account = await MainActor.run { UserScope.currentUserID }
                return try await CovenRepository.shared.connections(ofCoven: covenID, for: account)
            },
            apps: {
                var apps: [App] = []
                for provider in [ConnectedAppProvider.github, .googleDrive] {
                    let account = await ConnectedAccountsService.shared.getConnectedAccount(for: provider)
                    apps.append(App(id: provider.rawValue, name: provider.displayName, account: account?.displayName))
                }
                return apps
            },
            servers: {
                await ConnectedAccountsService.shared.getAllMCPServers().map(Server.init(account:))
            },
            save: { choice, covenID in
                try await CovenService.shared.setConnections(choice, forCoven: covenID)
            }
        )
    }

    let covenID: String
    private let sources: Sources

    /// The coven's choice as it is lived by: the one it made, or, while it
    /// has made none, everything connected.
    @Published private(set) var choice: CovenConnections?
    /// The coven has made no choice yet: it uses what it was already using.
    @Published private(set) var keptFromBefore = false
    @Published private(set) var apps: [App] = []
    @Published private(set) var servers: [Server] = []
    @Published private(set) var loadFailed = false
    /// The rows with a change being saved. Their controls wait for it, so
    /// a second change cannot overtake the first.
    @Published private(set) var saving: Set<String> = []
    @Published var errorMessage: String?

    /// Counts loads and changes: a load applies only if nothing newer
    /// started while it waited.
    private var generation = 0

    init(covenID: String, sources: Sources = .live) {
        self.covenID = covenID
        self.sources = sources
    }

    var isLoaded: Bool {
        choice != nil
    }

    func load() async {
        generation += 1
        let loading = generation
        do {
            let stored = try await sources.choice(covenID)
            let apps = await sources.apps()
            let servers = await sources.servers()
            guard loading == generation else { return }
            self.apps = apps
            self.servers = servers
            keptFromBefore = stored == nil
            choice = stored ?? .everything(apps: apps.filter { $0.account != nil }.map(\.id), mcpServers: servers.map(\.id))
            loadFailed = false
        } catch {
            guard loading == generation else { return }
            // What cannot be read is not shown as a choice of nothing.
            choice = nil
            loadFailed = true
        }
    }

    func access(ofApp id: String) -> CovenConnections.Access? {
        choice?.apps[id]
    }

    func access(ofServer id: String) -> CovenConnections.Access? {
        choice?.mcpServers[id]
    }

    func setApp(_ id: String, on: Bool) async {
        await change(row: "app:\(id)") { $0.turning(app: id, on: on) }
    }

    func setApp(_ id: String, access: CovenConnections.Access) async {
        await change(row: "app:\(id)") { $0.setting(app: id, to: access) }
    }

    func setServer(_ id: String, on: Bool) async {
        await change(row: "server:\(id)") { $0.turning(mcpServer: id, on: on) }
    }

    func setServer(_ id: String, access: CovenConnections.Access) async {
        await change(row: "server:\(id)") { $0.setting(mcpServer: id, to: access) }
    }

    func isSaving(app id: String) -> Bool {
        saving.contains("app:\(id)")
    }

    func isSaving(server id: String) -> Bool {
        saving.contains("server:\(id)")
    }

    /// Makes a change to the choice and keeps it. The screen shows the
    /// change at once and takes it back, saying so, if it cannot be kept.
    /// One change is saved at a time: each is made to the whole choice,
    /// so a second begun before the first is kept would undo it.
    private func change(row: String, _ make: (CovenConnections) -> CovenConnections) async {
        guard let before = choice, saving.isEmpty else { return }
        let after = make(before)
        guard after != before else { return }
        let wasKeptFromBefore = keptFromBefore
        generation += 1
        saving.insert(row)
        choice = after
        keptFromBefore = false
        do {
            try await sources.save(after, covenID)
        } catch {
            choice = before
            keptFromBefore = wasKeptFromBefore
            errorMessage = "That change could not be saved."
        }
        saving.remove(row)
    }
}

extension CovenConnectionsModel.Server {
    init(account: MCPServerAccount) {
        let tools = account.cachedTools ?? []
        let cannotConnect = account.status == .error
        self.init(
            id: account.id,
            name: account.name,
            line: cannotConnect ? "Can't connect. Test it in Settings." : (tools.count == 1 ? "1 tool" : "\(tools.count) tools"),
            cannotConnect: cannotConnect,
            marksReadOnlyTools: tools.contains(where: \.readOnlyHint)
        )
    }
}

/// A coven's Connections: the connected apps and MCP servers its agents
/// may use. As in the cloud app, each is on or off here, and one that is
/// on is on to read or to read and make changes.
struct CovenConnectionsView: View {
    let coven: Coven
    @StateObject private var model: CovenConnectionsModel

    init(coven: Coven, sources: CovenConnectionsModel.Sources = .live) {
        self.coven = coven
        _model = StateObject(wrappedValue: CovenConnectionsModel(covenID: coven.id, sources: sources))
    }

    var body: some View {
        SettingsForm {
            if model.isLoaded {
                appsSection
                serversSection
            } else if model.loadFailed {
                Section {
                    LabeledContent("Connections couldn't load.") {
                        Button("Try Again") { Task { await model.load() } }
                    }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("Connections")
        .task { await model.load() }
        .alert("Connections", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            if let message = model.errorMessage { Text(message) }
        }
        .accessibilityIdentifier("coven-connections")
    }

    // MARK: - Apps

    private var appsSection: some View {
        Section {
            ForEach(model.apps) { app in
                if let account = app.account {
                    Toggle(isOn: Binding(
                        get: { model.access(ofApp: app.id) != nil },
                        set: { on in Task { await model.setApp(app.id, on: on) } }
                    )) {
                        VStack(alignment: .leading, spacing: Spacing.xxxs) {
                            Text(app.name)
                            Text(account)
                                .font(.aicovenBodySmall)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .disabled(model.isSaving(app: app.id))
                    if let access = model.access(ofApp: app.id) {
                        accessPicker(for: app.name, access: access) { chosen in
                            Task { await model.setApp(app.id, access: chosen) }
                        }
                        .disabled(model.isSaving(app: app.id))
                    }
                } else {
                    LabeledContent(app.name) {
                        Text("Not connected")
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Apps")
        } footer: {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(
                    model.keptFromBefore
                        ? "\(coven.name) kept the accounts it was already using. Change any that don't belong here."
                        : "Agents in \(coven.name) use only the accounts chosen here."
                )
                Text("With Read, agents can look in an app but change nothing there. Apps are connected in Settings.")
            }
            .font(.aicovenBodySmall)
        }
    }

    // MARK: - MCP servers

    private var serversSection: some View {
        Section {
            if model.servers.isEmpty {
                Text("No MCP servers yet. Add one in Settings.")
                    .foregroundStyle(.secondary)
            }
            ForEach(model.servers) { server in
                Toggle(isOn: Binding(
                    get: { model.access(ofServer: server.id) != nil },
                    set: { on in Task { await model.setServer(server.id, on: on) } }
                )) {
                    VStack(alignment: .leading, spacing: Spacing.xxxs) {
                        Text(server.name)
                        Text(server.line)
                            .font(.aicovenBodySmall)
                            .foregroundStyle(server.cannotConnect ? Color.aicovenError : .secondary)
                    }
                }
                .disabled(model.isSaving(server: server.id))
                if let access = model.access(ofServer: server.id) {
                    accessPicker(for: server.name, access: access) { chosen in
                        Task { await model.setServer(server.id, access: chosen) }
                    }
                    .disabled(model.isSaving(server: server.id))
                }
            }
        } header: {
            Text("MCP Servers")
        } footer: {
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(
                    model.keptFromBefore
                        ? "\(coven.name) kept the servers it was already using. Turn off any that don't belong here."
                        : "Agents in \(coven.name) can use only the servers turned on here."
                )
                Text("With Read, agents can use only the tools a server marks as read-only. A server that marks none offers no tools.")
            }
            .font(.aicovenBodySmall)
        }
    }

    private func accessPicker(for name: String, access: CovenConnections.Access, choose: @escaping (CovenConnections.Access) -> Void) -> some View {
        Picker("Agents can", selection: Binding(
            get: { access },
            set: { chosen in
                guard chosen != access else { return }
                choose(chosen)
            }
        )) {
            ForEach(CovenConnections.Access.allCases, id: \.self) { mode in
                Text(mode.label).tag(mode)
            }
        }
        .accessibilityLabel("Agents can, \(name)")
    }
}
