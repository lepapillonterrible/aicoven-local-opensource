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
    }

    /// What the screen needs of the world, so tests can stand in for it.
    struct Sources {
        var choice: @Sendable (_ covenID: String) async throws -> CovenConnections?
        var apps: @Sendable () async -> [App]
        var servers: @Sendable () async -> [Server]
        /// Changes the coven's stored choice in one write: `make` is given
        /// the choice as it is stored then (`unchosen` where the coven
        /// has made none), and what it gives back is kept and returned.
        var change: @Sendable (_ covenID: String, _ unchosen: CovenConnections, _ make: @escaping @Sendable (CovenConnections) throws -> CovenConnections) async throws -> CovenConnections
        /// The name Figma has now for the file or project a link names,
        /// asked as the connected Figma account.
        var figmaName: @Sendable (_ link: FigmaToolService.Link) async throws -> String = { _ in throw FigmaAddError.notConnected }
        /// Who is signed in.
        var account: @MainActor @Sendable () -> String = { UserScope.currentUserID }
        /// Tells VoiceOver what came of something.
        var say: @MainActor @Sendable (String) -> Void = { AccessibilityNotification.Announcement($0).post() }

        static let live = Sources(
            choice: { covenID in
                let account = await MainActor.run { UserScope.currentUserID }
                return try await CovenRepository.shared.connections(ofCoven: covenID, for: account)
            },
            apps: {
                var apps: [App] = []
                for provider in ConnectedAppProvider.allCases {
                    let account = await ConnectedAccountsService.shared.getConnectedAccount(for: provider)
                    apps.append(App(id: provider.rawValue, name: provider.displayName, account: account?.displayName))
                }
                return apps
            },
            servers: {
                await ConnectedAccountsService.shared.getAllMCPServers().map(Server.init(account:))
            },
            change: { covenID, unchosen, make in
                try await CovenService.shared.changeConnections(ofCoven: covenID, unchosen: unchosen, make)
            },
            figmaName: { link in
                let accounts = ConnectedAccountsService.shared
                guard let account = await accounts.getConnectedAccount(for: .figma) else { throw FigmaAddError.notConnected }
                let token = try await accounts.getAccessToken(forAccountId: account.id)
                do {
                    switch link {
                    case let .file(key): return try await FigmaToolService.fileMeta(key: key, token: token).name
                    case let .folder(id): return try await FigmaToolService.folderFiles(id: id, token: token).name
                    }
                } catch FigmaError.tokenRefused {
                    // The token that was refused is the one marked.
                    await accounts.markTokenRefused(accountID: account.id, token: token)
                    throw FigmaError.tokenRefused
                }
            }
        )
    }

    /// Why a link's file or project could not be asked for.
    enum FigmaAddError: Error {
        case notConnected
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
    /// A link's file or project is being looked up and added.
    @Published private(set) var isAddingFigma = false
    /// Why the last link was not added, shown under the link's field.
    @Published private(set) var figmaAddError: String?
    /// Counts the edits of the link's field: what is found out about a
    /// link is said only while the field still holds it.
    private var figmaLinkEdits = 0

    /// Counts loads and changes: a load applies only if nothing newer
    /// started while it waited.
    private var generation = 0
    /// A load was asked for while a change was being saved, and waits for it.
    private var loadWaits = false

    init(covenID: String, sources: Sources = .live) {
        self.covenID = covenID
        self.sources = sources
    }

    var isLoaded: Bool {
        choice != nil
    }

    func load() async {
        // A change being saved is newer than anything read now, and what
        // is read now may be from before it. The load waits for the change.
        guard saving.isEmpty else {
            loadWaits = true
            return
        }
        generation += 1
        let loading = generation
        // Trying again shows that it is loading, not the last failure.
        if choice == nil { loadFailed = false }
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

    // MARK: - Figma files and projects

    /// The coven's Figma files and projects, as chosen.
    var figma: CovenConnections.FigmaChoice {
        choice?.figma ?? CovenConnections.FigmaChoice()
    }

    /// A change to the Figma files or projects is being saved: the rows
    /// wait for it.
    var isSavingFigma: Bool {
        saving.contains("figma")
    }

    /// Adds the file or project a pasted link names to the coven's Figma
    /// choice, named as Figma names it now. True once the link is done
    /// with (added, or chosen already), when its field can be emptied.
    /// One link at a time, as the account that pasted it: what comes of
    /// it is said to no other.
    func addFigma(link pasted: String) async -> Bool {
        guard choice != nil, !isAddingFigma else { return false }
        let account = sources.account()
        let edits = figmaLinkEdits
        guard let link = FigmaToolService.link(pasted) else {
            return failFigma("That isn't a Figma file or project link.")
        }
        /// Says why not, to the account that pasted the link and while
        /// its field still holds that link: of a link typed since,
        /// nothing was found out.
        func fail(_ message: String) -> Bool {
            guard sources.account() == account, figmaLinkEdits == edits else { return false }
            return failFigma(message)
        }
        isAddingFigma = true
        defer { isAddingFigma = false }
        figmaAddError = nil
        let name: String
        do {
            name = try await sources.figmaName(link)
        } catch {
            if error is FigmaAddError {
                return fail("Figma isn't connected. Connect it in Settings, then add the link again.")
            }
            switch error as? FigmaError {
            case .tokenRefused?:
                return fail("Figma refused this account's token. Replace the token in Settings, then add the link again.")
            case .forbidden?, .notFound?:
                return fail("This Figma account can't open that.")
            case .rateLimited?:
                return fail("Figma is limiting how often this account asks. Try again in a while.")
            default:
                return fail("Figma didn't answer. Try again.")
            }
        }
        guard sources.account() == account else { return false }
        // Added to the choice as it is stored when it is written, not as
        // it was when Add was pressed: a removal saved meanwhile stays
        // removed.
        let outcome = await change(row: "figma", saysFailure: false) { now in
            switch link {
            case let .file(key): try now.addingFigma(file: .init(id: key, name: name))
            case let .folder(id): try now.addingFigma(folder: .init(id: id, name: name))
            }
        }
        guard sources.account() == account else { return false }
        switch outcome {
        case .kept:
            sources.say("Added \(FigmaToolService.listedName(name))")
            return true
        case .unchanged, .refused(.alreadyChosen):
            // Chosen already: the link is done with.
            return true
        case .refused(.tooMany):
            if case .file = link {
                return fail("This coven already has \(CovenConnections.FigmaChoice.mostFiles) Figma files. Remove one to add another.")
            }
            return fail("This coven already has \(CovenConnections.FigmaChoice.mostFolders) Figma projects. Remove one to add another.")
        case .failed:
            return fail("That couldn't be added. Try again.")
        }
    }

    /// Takes a file, or a project, out of the coven's Figma choice.
    func removeFigma(file id: String) async {
        guard let name = figma.files.first(where: { $0.id == id })?.name else { return }
        let account = sources.account()
        if await change(row: "figma", { $0.removingFigma(file: id) }) == .kept, sources.account() == account {
            sources.say("Removed \(name)")
        }
    }

    func removeFigma(folder id: String) async {
        guard let name = figma.folders.first(where: { $0.id == id })?.name else { return }
        let account = sources.account()
        if await change(row: "figma", { $0.removingFigma(folder: id) }) == .kept, sources.account() == account {
            sources.say("Removed \(name)")
        }
    }

    /// The link's field holds something else now: what was said of the
    /// link before is not about it, and what is still being found out
    /// about that link will not be said of this one.
    func figmaLinkChanged() {
        figmaLinkEdits += 1
        figmaAddError = nil
    }

    private func failFigma(_ message: String) -> Bool {
        figmaAddError = message
        sources.say(message)
        return false
    }

    /// What came of a change to the choice.
    enum Outcome: Equatable {
        case kept
        /// It changes nothing of what is shown.
        case unchanged
        /// The choice does not take it: there already, or too many.
        case refused(CovenConnections.FigmaRefusal)
        case failed
    }

    /// Makes a change to the choice and keeps it. The screen shows the
    /// change at once and takes it back, saying so, if it cannot be kept.
    /// One change of this screen's is saved at a time. The store makes
    /// the change to the choice as it is stored when it is written, so
    /// what another window changed since this one read the choice is not
    /// undone; what was kept is then what is shown. Whether the choice
    /// takes a change (a file there already, too many) is the store's to
    /// say, of the choice as it is stored: what this screen last read
    /// only decides what it shows meanwhile.
    @discardableResult
    private func change(row: String, saysFailure: Bool = true, _ make: @escaping @Sendable (CovenConnections) throws -> CovenConnections) async -> Outcome {
        guard let before = choice, saving.isEmpty else { return .failed }
        let shown = try? make(before)
        // A change that leaves what is shown as it is has nothing to keep.
        if shown == before { return .unchanged }
        let wasKeptFromBefore = keptFromBefore
        generation += 1
        saving.insert(row)
        if let shown {
            choice = shown
            keptFromBefore = false
        }
        var outcome = Outcome.kept
        do {
            choice = try await sources.change(covenID, before, make)
            keptFromBefore = false
        } catch {
            choice = before
            keptFromBefore = wasKeptFromBefore
            if let refusal = error as? CovenConnections.FigmaRefusal {
                // What is stored is not what was shown: it is read again.
                outcome = .refused(refusal)
                loadWaits = true
            } else {
                outcome = .failed
                if saysFailure { errorMessage = "That change could not be saved." }
            }
        }
        saving.remove(row)
        if loadWaits {
            loadWaits = false
            await load()
        }
        return outcome
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
            cannotConnect: cannotConnect
        )
    }
}

/// A coven's Connections: the connected apps and MCP servers its agents
/// may use. As in the cloud app, each is on or off here, and one that is
/// on is on to read or to read and make changes.
struct CovenConnectionsView: View {
    let coven: Coven
    @StateObject private var model: CovenConnectionsModel
    @State private var figmaLink = ""

    init(coven: Coven, sources: CovenConnectionsModel.Sources = .live) {
        self.coven = coven
        _model = StateObject(wrappedValue: CovenConnectionsModel(covenID: coven.id, sources: sources))
    }

    var body: some View {
        SettingsForm {
            if model.isLoaded {
                appsSection
                if model.access(ofApp: ConnectedAppProvider.figma.rawValue) != nil, model.apps.contains(where: { $0.id == ConnectedAppProvider.figma.rawValue && $0.account != nil }) {
                    figmaSections
                }
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

    // MARK: - Figma files and projects

    /// The coven's Figma files and projects, as the cloud app's: each is
    /// added by pasting its link and listed by the name Figma has for it.
    @ViewBuilder private var figmaSections: some View {
        Section {
            TextField("Link", text: $figmaLink, prompt: Text("Paste a Figma file or project link"))
                .textContentType(.URL)
            #if os(iOS)
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
            #endif
                .autocorrectionDisabled()
                .onSubmit { addFigmaLink() }
                .onChange(of: figmaLink) { model.figmaLinkChanged() }
            Button(action: addFigmaLink) {
                HStack(spacing: Spacing.xs) {
                    Text(model.isAddingFigma ? "Adding…" : "Add")
                    if model.isAddingFigma { ProgressView().controlSize(.small) }
                }
            }
            .disabled(model.isAddingFigma || figmaLink.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if let problem = model.figmaAddError {
                Text(problem)
                    .font(.aicovenBodySmall)
                    .foregroundStyle(Color.aicovenError)
            }
        } header: {
            Text("Figma: Add a File or Project")
        } footer: {
            Text("A project's link is in Figma's address bar when the project is open; a file's link doesn't name its project.")
                .font(.aicovenBodySmall)
        }

        Section {
            if model.figma.files.isEmpty {
                Text("No files").foregroundStyle(.secondary)
            }
            ForEach(model.figma.files) { file in
                figmaRow(file.name, systemImage: "doc") { await model.removeFigma(file: file.id) }
            }
        } header: {
            Text("Figma Files")
        }

        Section {
            if model.figma.folders.isEmpty {
                Text("No projects").foregroundStyle(.secondary)
            }
            ForEach(model.figma.folders) { folder in
                figmaRow(folder.name, detail: "Includes files added to this folder later", systemImage: "folder") { await model.removeFigma(folder: folder.id) }
            }
        } header: {
            Text("Figma Projects")
        } footer: {
            if model.figma.isEmpty {
                Text(
                    model.keptFromBefore
                        ? "Nothing is chosen. \(coven.name) hasn't changed its connections yet, so its agents can open any Figma file this account can. Once anything here is changed, they can open only the files and projects chosen here."
                        : "Nothing is chosen, so agents in \(coven.name) can't open any Figma file."
                )
                .font(.aicovenBodySmall)
            }
        }
    }

    private func figmaRow(_ name: String, detail: String? = nil, systemImage: String, remove: @escaping () async -> Void) -> some View {
        HStack(spacing: Spacing.sm) {
            Label {
                VStack(alignment: .leading, spacing: Spacing.xxxs) {
                    Text(name)
                    if let detail {
                        Text(detail)
                            .font(.aicovenBodySmall)
                            .foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: systemImage)
            }
            Spacer(minLength: 0)
            Button {
                Task { await remove() }
            } label: {
                Image(systemName: "minus.circle")
                #if os(iOS)
                    .frame(minWidth: 44, minHeight: 44)
                #else
                    .frame(minWidth: 28, minHeight: 28)
                #endif
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .disabled(model.isSavingFigma)
            .accessibilityLabel("Remove \(name)")
        }
    }

    private func addFigmaLink() {
        let pasted = figmaLink
        guard !pasted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !model.isAddingFigma else { return }
        Task {
            // The field is emptied only if it still holds what was added.
            if await model.addFigma(link: pasted), figmaLink == pasted { figmaLink = "" }
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
