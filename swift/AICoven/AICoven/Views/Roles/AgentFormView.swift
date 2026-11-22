import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Adds or edits one of a coven's agents, as the cloud app's form: the face
/// and Name, Instructions, the Runs on menu, Description, an Advanced
/// disclosure, and Delete Agent last. The Mac shows it as a sheet with
/// stone header and footer bars; on the iPhone and iPad it is a page with
/// Save in the navigation bar, inside the stack of whoever shows it.
struct AgentFormView: View {
    enum Mode: Equatable {
        case add(covenId: String)
        case edit(roleId: String)
    }

    let mode: Mode
    /// The coven the agent is in, for what deleting it says.
    let covenName: String
    /// Leaves the form unsaved.
    let onCancel: () -> Void
    /// Runs after a save or a delete has landed: whoever shows the form
    /// closes it and reads the agents again.
    let onFinished: () -> Void

    @Environment(\.isPadLayout) private var isPadLayout
    @StateObject private var choices = AgentModelChoices()
    @State private var draft = AgentDraft()
    @State private var loadFailed = false
    @State private var loading = true
    /// Counts loads; only the newest one applies what it read, so an older
    /// one finishing late (a second Try Again, a restarted `.task`) is
    /// ignored.
    @State private var loadGeneration = 0
    /// Set after the first load, so the form keeps the edits instead of
    /// reading the saved agent again.
    @State private var loaded = false
    @State private var savePhase: ActionPhase = .idle
    @State private var deletePhase: ActionPhase = .idle
    @State private var actionError: String?
    /// The name the agent was saved with, which Delete names.
    @State private var savedName = ""
    @State private var showAddAccount = false
    /// What was so when Add AI Connection… was pressed: the connections
    /// there were, and how many choices had been made in Runs on.
    @State private var addingFrom: (known: Set<String>, choices: Int)?
    @State private var showAdvanced = false
    @State private var confirmDelete = false
    @State private var isOnScreen = false
    #if os(macOS)
    /// The window the form is in, whose editing ends before it closes.
    @State private var formWindow = FormWindow()
    #endif

    private let analytics = AnalyticsService.shared

    static let addFailure = "Couldn't add the agent. Try again."
    static let saveFailure = "Couldn't save the agent. Try again."
    static let deleteFailure = "Couldn't delete the agent. Try again."

    private var isAdd: Bool {
        if case .add = mode { return true }
        return false
    }

    private var title: String {
        isAdd ? "New Agent" : (draft.name.isEmpty ? "Agent" : draft.name)
    }

    /// An agent of the person's own (Hermes, OpenClaw through its Gateway)
    /// runs its turns itself: no model is named, and none of the settings
    /// under Advanced reach it.
    private var runsItself: Bool {
        choices.runsItself(accountId: draft.accountId, provider: draft.provider)
    }

    private var usesTemperature: Bool {
        choices.usesTemperature(accountId: draft.accountId, provider: draft.provider, model: draft.model)
    }

    private var usesMaxTokens: Bool {
        choices.usesMaxTokens(accountId: draft.accountId, provider: draft.provider)
    }

    private var usesSteps: Bool {
        choices.usesSteps(accountId: draft.accountId, provider: draft.provider)
    }

    /// What Save would store; nil where the form cannot be saved as it is.
    private var saving: AgentSaving? {
        draft.saving(usesTemperature: usesTemperature, usesMaxTokens: usesMaxTokens, usesSteps: usesSteps, needsModel: !runsItself)
    }

    private var canSave: Bool {
        saving != nil && savePhase == .idle && deletePhase == .idle && !loading && !loadFailed
    }

    var body: some View {
        container
            .confirmationDialog("Delete \(savedName)?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Delete", role: .destructive) {
                    // For the account that said so: read here, not when
                    // the delete's turn comes. Working from this moment.
                    guard case let .edit(roleId) = mode, deletePhase == .idle, savePhase == .idle else { return }
                    let account = UserScope.currentUserID
                    actionError = nil
                    deletePhase = .working
                    Task { await delete(roleId, as: account) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Its threads keep their replies. \(savedName) stops answering in \(covenName).")
            }
            .sheet(isPresented: $showAddAccount) {
                // What it made is found by reading the connections again.
                AddProviderKeySheet { Task { await accountAdded() } }
            }
            .task {
                guard !loaded else { return }
                await load()
            }
            // The other connections' model lists fill the Runs on menu; the
            // chosen one's is read by `load()` and `choose`.
            .task(id: loading ? [] : choices.accounts.map(\.id)) {
                await readOtherModels()
            }
            .onAppear {
                isOnScreen = true
                analytics.trackScreenView(screenName: isAdd ? "AddRoleView" : "EditRoleView", screenClass: "AgentFormView")
            }
            .onDisappear { isOnScreen = false }
    }

    private func readOtherModels() async {
        for account in choices.accounts
            where account.id != draft.accountId && choices.models(for: account.id).isEmpty
            && !choices.runsItself(accountId: account.id, provider: account.provider) {
            await choices.loadModels(for: account.id)
        }
    }

    @ViewBuilder
    private var container: some View {
        #if os(macOS)
        VStack(spacing: 0) {
            Text(title)
                .font(.aicovenH3)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .frame(height: 44)
                .background(Color.aicovenChrome)
            Rectangle().fill(Color.aicovenRule).frame(height: 1)
            content
            Rectangle().fill(Color.aicovenRule).frame(height: 1)
            HStack(spacing: Spacing.xs) {
                errorLine
                Spacer(minLength: Spacing.sm)
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .disabled(savePhase == .working || deletePhase == .working)
                Button {
                    pressSave()
                } label: {
                    ActionPhaseLabel("Save", phase: savePhase)
                }
                .buttonStyle(StonePrimaryButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(!canSave)
            }
            .padding(.horizontal, Spacing.sm)
            .frame(height: 52)
            .background(Color.aicovenChrome)
        }
        .frame(width: 620)
        .frame(minHeight: 480, idealHeight: 768, maxHeight: 768)
        .background(Color.aicovenSurfaceElevated)
        .background(FormWindowReader(holder: formWindow))
        .interactiveDismissDisabled(savePhase == .working || deletePhase == .working)
        #else
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            // Leaving while a save runs would let it land after the form closed.
            .interactiveDismissDisabled(savePhase == .working || deletePhase == .working)
            .toolbar {
                StoneToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                        .disabled(savePhase == .working || deletePhase == .working)
                }
                StoneToolbarItem(placement: .confirmationAction) {
                    Button {
                        pressSave()
                    } label: {
                        ActionPhaseLabel("Save", phase: savePhase)
                    }
                    .disabled(!canSave)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if actionError != nil {
                    errorLine
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Spacing.md)
                        .background(Color.aicovenSurface)
                }
            }
        #endif
    }

    @ViewBuilder
    private var errorLine: some View {
        if let actionError {
            Text(actionError)
                .font(.aicovenBodySmall)
                .foregroundStyle(Color.aicovenError)
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private var content: some View {
        if loading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if loadFailed {
            ContentUnavailableView {
                Label(isAdd ? "Couldn't load your AI connections" : "Couldn't load this agent", systemImage: "exclamationmark.triangle")
            } actions: {
                Button("Try Again") { Task { await load() } }
            }
        } else {
            form
        }
    }

    // MARK: - Fields

    /// The instructions field's least height: about 12 lines on the Mac, 10
    /// on the iPad, and on the iPhone enough to be on screen without
    /// scrolling under the face and name.
    private var instructionsMinHeight: CGFloat {
        #if os(macOS)
        return 276
        #else
        return isPadLayout ? 246 : 296
        #endif
    }

    /// The form's column in the iPad's layout; the Mac sheet and the phone
    /// layout fill their width.
    private var formWidth: CGFloat {
        isPadLayout ? 600 : .infinity
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                faceAndName
                instructions
                AgentRunsOnRow(
                    choices: choices,
                    draft: draft,
                    onChoose: { account, model in choose(account, model: model) },
                    onAdd: {
                        addingFrom = (Set(choices.accounts.map(\.id)), draft.choicesMade)
                        showAddAccount = true
                    }
                )
                .disabled(savePhase != .idle)
                .padding(.top, Spacing.md)
                textField("Description", text: $draft.description, prompt: "Optional", axis: .vertical)
                    .padding(.top, Spacing.md)
                if usesTemperature || usesMaxTokens || usesSteps || !runsItself {
                    advanced
                        .padding(.top, Spacing.sm)
                }
                if !isAdd {
                    deleteRow
                }
            }
            .frame(maxWidth: formWidth, alignment: .leading)
            .padding(.horizontal, Spacing.md)
            .padding(.top, Spacing.md)
            .padding(.bottom, Spacing.lg)
            .frame(maxWidth: .infinity)
        }
        #if os(iOS)
        .background(Color.aicovenSurface)
        .scrollDismissesKeyboard(.interactively)
        #endif
    }

    private var faceAndName: some View {
        HStack(alignment: .top, spacing: Spacing.md) {
            IconChoice(
                symbol: $draft.iconSymbol,
                tint: Binding(get: { draft.iconTint ?? .warm }, set: { draft.iconTint = $0 }),
                suggestedSymbols: AgentFace.suggestedSymbols
            ) {
                AgentFace(symbol: draft.iconSymbol, tint: draft.iconTint, provider: draft.provider, size: 64)
                    .accessibilityHidden(true)
            }
            textField("Name", text: $draft.name, prompt: "Name")
                .padding(.top, Spacing.xs)
        }
    }

    private var instructions: some View {
        let name = draft.name.trimmingCharacters(in: .whitespaces)
        return VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("Instructions")
                .font(.aicovenH2)
                .padding(.top, Spacing.md)
                .accessibilityAddTraits(.isHeader)
            // A hidden copy of the text sets the field's height, because
            // `TextEditor` does not size itself to its text: as tall as the
            // text plus a spare line, and never under the least height. The
            // padding is at least the editor's own inset.
            Text(verbatim: draft.instructions + "\n ")
                .font(.aicovenBody)
                .padding(Spacing.sm)
                .frame(maxWidth: .infinity, minHeight: instructionsMinHeight, alignment: .topLeading)
                .hidden()
                .overlay(alignment: .topLeading) {
                    TextEditor(text: $draft.instructions)
                        .font(.aicovenBody)
                        .scrollContentBackground(.hidden)
                        .scrollDisabled(true)
                        .accessibilityLabel("Instructions")
                        .overlay(alignment: .topLeading) {
                            if draft.instructions.isEmpty {
                                Text("What should this agent do?")
                                    .font(.aicovenBody)
                                    .foregroundStyle(Color.aicovenTextTertiary)
                                    .padding(.leading, 5)
                                #if os(iOS)
                                    .padding(.top, 8)
                                #endif
                                    .allowsHitTesting(false)
                                    .accessibilityHidden(true)
                            }
                        }
                }
                .modifier(AgentFieldBox())
            Text("What should \(name.isEmpty ? "this agent" : name) do, and how? Every reply follows this.")
                .font(.aicovenBodySmall)
                .foregroundStyle(Color.aicovenTextTertiary)
        }
    }

    /// Temperature and Max tokens where the agent's turns use them, Most
    /// steps unless the agent runs its own, and the model's id.
    private var advanced: some View {
        DisclosureGroup(isExpanded: $showAdvanced) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                if usesTemperature {
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        HStack {
                            Text("Temperature")
                            Spacer()
                            Text(draft.temperature.formatted(.number.precision(.fractionLength(1))))
                                .foregroundStyle(Color.aicovenTextSecondary)
                        }
                        .accessibilityHidden(true)
                        Slider(value: $draft.temperature, in: 0 ... 2, step: 0.1)
                            .accessibilityLabel("Temperature")
                            .accessibilityValue(draft.temperature.formatted(.number.precision(.fractionLength(1))))
                        Text("Lower temperature is more focused, higher more creative.")
                            .font(.aicovenBodySmall)
                            .foregroundStyle(Color.aicovenTextTertiary)
                    }
                }
                if usesMaxTokens {
                    textField("Max tokens", text: $draft.maxTokens, prompt: "2000", numeric: true)
                }
                if usesSteps {
                    VStack(alignment: .leading, spacing: Spacing.xxs) {
                        textField("Most steps", text: $draft.maxSteps, prompt: "30", numeric: true)
                        Text("The most tool steps it takes to answer one message, from 1 to \(AgentSaving.mostStepsAllowed).")
                            .font(.aicovenBodySmall)
                            .foregroundStyle(Color.aicovenTextTertiary)
                    }
                }
                if !runsItself {
                    textField("Model ID", text: $draft.model, prompt: "Model ID")
                }
            }
            .padding(.top, Spacing.xs)
        } label: {
            Text("Advanced")
                .font(.aicovenBodyMedium)
                .foregroundStyle(Color.aicovenTextSecondary)
        }
    }

    private var deleteRow: some View {
        VStack(spacing: 0) {
            Rectangle().fill(Color.aicovenRule).frame(height: 1)
                .padding(.top, Spacing.md)
            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                ActionPhaseLabel("Delete Agent…", phase: deletePhase)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.aicovenError)
            .disabled(deletePhase != .idle || savePhase != .idle)
            .accessibilityLabel("Delete Agent")
        }
    }

    /// A caption over a bordered field. Long text wraps, up to four lines,
    /// where the field's axis is vertical.
    private func textField(
        _ label: String,
        text: Binding<String>,
        prompt: String,
        axis: Axis = .horizontal,
        numeric: Bool = false
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xxs) {
            Text(label)
                .font(.aicovenCaption.weight(.semibold))
                .foregroundStyle(Color.aicovenTextTertiary)
                .accessibilityHidden(true)
            TextField(label, text: text, prompt: Text(prompt), axis: axis)
                .textFieldStyle(.plain)
                .lineLimit(axis == .vertical ? 1 ... 4 : 1 ... 1)
                .autocorrectionDisabled(label == "Model ID")
            #if os(iOS)
                .keyboardType(numeric ? .numberPad : .default)
                .textInputAutocapitalization(label == "Model ID" ? .never : nil)
            #endif
                .padding(.horizontal, Spacing.sm)
                .frame(minHeight: PlatformCapabilities.current.platform == .iOS ? 44 : 36)
                .modifier(AgentFieldBox())
        }
    }

    // MARK: - Loading and choosing

    private func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        loading = true
        loadFailed = false
        defer {
            if generation == loadGeneration { loading = false }
        }
        switch mode {
        case let .add(covenId):
            let accountsFailed = await (try? choices.loadAccounts()) == nil
            guard generation == loadGeneration else { return }
            if accountsFailed {
                loadFailed = true
                return
            }
            loaded = true
            // A new agent starts on the connection of Strix's provider, on
            // its default model, as choosing it in Runs on does.
            let strixProvider = UserDefaults.standard.string(forKey: UserScope.scopedKey("llm_provider"))
            if let account = choices.newAgentDefault(strixProvider: strixProvider) {
                draft.moveToAccount(account)
            }
            // A new agent wears the first tint no other agent of the coven
            // does. Where the agents cannot be read none is shown as
            // chosen, and one is picked as the agent is made.
            let roles = try? await RoleService.shared.loadRoles(covenId: covenId)
            guard generation == loadGeneration else { return }
            if let roles {
                draft.iconTint = AgentDraft.startingTint(among: roles)
            }
        case let .edit(roleId):
            let role = try? await RoleService.shared.getRole(roleId: roleId)
            guard generation == loadGeneration else { return }
            guard let role else {
                loadFailed = true
                return
            }
            savedName = role.name
            _ = try? await choices.loadAccounts()
            guard generation == loadGeneration else { return }
            draft = AgentDraft(role: role)
            loaded = true
            // A connection removed since leaves the agent on the connection
            // of its provider, which is what its turns go by; with none of
            // that provider the picker asks for one. A list that could not
            // be read says nothing about the connection, so the agent
            // keeps it.
            if choices.accountsLoaded, choices.account(draft.accountId) == nil {
                draft.accountId = choices.accounts.first { $0.provider.lowercased() == draft.provider }?.id
            }
        }
        if let accountId = draft.accountId, !runsItself {
            await choices.loadModels(for: accountId)
            guard generation == loadGeneration, draft.accountId == accountId else { return }
            draft.takeLoadedModels(choices.models(for: accountId), isNewAgent: isAdd)
        }
    }

    /// Chooses the Runs on item: the connection and, when the item was one
    /// of its models, that model. Another connection takes the agent over
    /// with its own default model until its list is read, never the old
    /// connection's.
    private func choose(_ account: ProviderAccount, model: String? = nil) {
        guard draft.choose(account, model: model),
              !choices.runsItself(accountId: account.id, provider: account.provider) else { return }
        // The model as it is now: the read changes it only if it is still this.
        let chosen = draft.model
        Task {
            await choices.loadModels(for: account.id)
            draft.takeModels(choices.models(for: account.id), of: account.id, readWhenModelWas: chosen)
        }
    }

    /// A connection added from the form is chosen, if it is the one new
    /// connection and nothing was chosen in Runs on since Add AI
    /// Connection… was pressed.
    private func accountAdded() async {
        guard let addingFrom else { return }
        let generation = loadGeneration
        guard await (try? choices.loadAccounts()) != nil, generation == loadGeneration,
              draft.choicesMade == addingFrom.choices,
              let added = AgentDraft.added(to: addingFrom.known, in: choices.accounts) else { return }
        choose(added)
    }

    // MARK: - Saving and deleting

    private func pressSave() {
        // What is saved is what the form shows as Save is pressed, for the
        // account that pressed it. The form is working from this moment,
        // so a second press does nothing.
        guard canSave, let saving else { return }
        let account = UserScope.currentUserID
        actionError = nil
        savePhase = .working
        Task { await save(saving, as: account) }
    }

    private func save(_ agent: AgentSaving, as account: String) async {
        do {
            switch mode {
            case let .add(covenId):
                let made = try await RoleService.shared.createAgent(inCoven: covenId, agent, as: account)
                analytics.trackRoleCreate(roleId: made.id, templateId: nil, isCustom: true)
            case let .edit(roleId):
                _ = try await RoleService.shared.saveAgent(roleId, agent, as: account)
                analytics.trackRoleUpdate(roleId: roleId, field: "all")
            }
            // The form stays working while whoever shows it closes it: a
            // press on Save as the sheet leaves makes no second agent.
            finish()
        } catch {
            // The kind of failure only.
            AppErrorReporter.log(message: "Could not save an agent (\(type(of: error)))", context: "AgentFormView.save")
            await failed(isAdd ? Self.addFailure : Self.saveFailure, phase: $savePhase)
        }
    }

    private func delete(_ roleId: String, as account: String) async {
        do {
            try await RoleService.shared.deleteRole(roleId: roleId, as: account)
            analytics.trackRoleDelete(roleId: roleId)
            // Working until the form is closed, as after a save.
            finish()
        } catch {
            AppErrorReporter.log(message: "Could not delete an agent (\(type(of: error)))", context: "AgentFormView.delete")
            await failed(Self.deleteFailure, phase: $deletePhase)
        }
    }

    /// Says what failed where it shows and, while the form is on screen,
    /// to VoiceOver: nothing of it to an account that did not ask.
    private func failed(_ text: String, phase: Binding<ActionPhase>) async {
        actionError = text
        if isOnScreen { AccessibilityNotification.Announcement(text).post() }
        await ActionPhase.settle(phase, to: .failed)
    }

    private func finish() {
        #if os(macOS)
        // A focused NSTextView torn down mid-update crashes AppKit; end
        // editing before the sheet closes. In the form's own window: by
        // now another window may be the one in front.
        formWindow.window?.makeFirstResponder(nil)
        #endif
        onFinished()
    }
}

#if os(macOS)
/// The window a form is in, once the form is in one.
private final class FormWindow {
    weak var window: NSWindow?
}

/// Notes the window its view is put in.
private struct FormWindowReader: NSViewRepresentable {
    let holder: FormWindow

    func makeNSView(context _: Context) -> NSView {
        Reader(holder: holder)
    }

    func updateNSView(_: NSView, context _: Context) {}

    private final class Reader: NSView {
        let holder: FormWindow

        init(holder: FormWindow) {
            self.holder = holder
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("Not made from a coder")
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            holder.window = window
        }
    }
}
#endif

/// A bordered, filled field: the page's other fill on the Mac sheet and the
/// iPhone and iPad pages.
private struct AgentFieldBox: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: BorderRadius.sm)
                    .fill(fill)
                    .overlay(RoundedRectangle(cornerRadius: BorderRadius.sm).strokeBorder(Color.aicovenBorder, lineWidth: 1))
            )
    }

    private var fill: Color {
        #if os(macOS)
        Color.aicovenSurface
        #else
        Color.aicovenSurfaceElevated
        #endif
    }
}
