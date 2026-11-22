import SwiftUI

/// An agent's "Runs on {model} · {connection}" line, as the cloud app's:
/// one menu with a section per connection, its models under it with the
/// current one ticked, and Add AI Connection last. A saved model the
/// connection's list leaves out stays, and says so.
struct AgentRunsOnRow: View {
    @ObservedObject var choices: AgentModelChoices
    let draft: AgentDraft
    /// Chooses the connection, and one of its models when the item was one.
    let onChoose: (ProviderAccount, String?) -> Void
    let onAdd: () -> Void

    private var account: ProviderAccount? {
        choices.account(draft.accountId)
    }

    private var connectionName: String {
        choices.connectionName(accountId: draft.accountId, provider: draft.provider)
    }

    private var line: String {
        guard draft.accountId != nil else { return "Choose a connection" }
        return AgentModelChoices.modelLine(
            model: draft.model,
            models: choices.models(for: draft.accountId),
            connection: connectionName
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.xs) {
                Text("Runs on")
                    .foregroundStyle(Color.aicovenTextSecondary)
                    .accessibilityHidden(true)
                menu
                Spacer(minLength: 0)
            }
            if AgentModelChoices.isUnlisted(model: draft.model, models: choices.models(for: draft.accountId)),
               !choices.runsItself(accountId: draft.accountId, provider: draft.provider) {
                Text("\(draft.model) isn't in \(connectionName)'s current model list, so it may not run. Choose another model in Runs on.")
                    .font(.aicovenBodySmall)
                    .foregroundStyle(Color.aicovenError)
            }
            if choices.accountsLoaded, choices.accounts.isEmpty {
                Text("No AI connection yet. Add one to choose what this agent runs on.")
                    .font(.aicovenBodySmall)
                    .foregroundStyle(Color.aicovenTextSecondary)
            }
        }
    }

    private var menu: some View {
        Menu {
            ForEach(choices.accounts) { section(for: $0) }
            Divider()
            Button("Add AI Connection…", action: onAdd)
        } label: {
            HStack(spacing: Spacing.xs) {
                if let logo = account.map({ providerLogoAssetName(slug: $0.provider) }), !logo.isEmpty {
                    ProviderLogoBadge(assetName: logo, size: 16)
                }
                Text(line)
                    .lineLimit(1)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.aicovenCaption)
                    .accessibilityHidden(true)
            }
            .foregroundStyle(Color.aicovenTextPrimary)
            .padding(.horizontal, Spacing.sm)
            .frame(minHeight: 32)
            .background(
                RoundedRectangle(cornerRadius: BorderRadius.sm)
                    .fill(Color.aicovenSurfaceElevated)
                    .overlay(RoundedRectangle(cornerRadius: BorderRadius.sm).strokeBorder(Color.aicovenBorder, lineWidth: 1))
            )
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityLabel("Runs on")
        .accessibilityValue(line)
    }

    /// One connection: its models, or one item that chooses it when it
    /// lists none or is an agent of the person's own, which runs its turns
    /// itself whatever model is named here.
    private func section(for account: ProviderAccount) -> some View {
        let models = choices.runsItself(accountId: account.id, provider: account.provider) ? [] : choices.models(for: account.id)
        let isCurrent = draft.accountId == account.id
        return Section {
            if models.isEmpty {
                item(account.displayName, ticked: isCurrent) { onChoose(account, nil) }
            } else {
                ForEach(models) { metadata in
                    item(metadata.name ?? metadata.id, ticked: isCurrent && draft.model == metadata.id) {
                        onChoose(account, metadata.id)
                    }
                }
            }
        } header: {
            let logo = providerLogoAssetName(slug: account.provider)
            if logo == ProviderLogoBadge.serverSymbolAssetName {
                Label(account.displayName, systemImage: "server.rack")
            } else if logo.isEmpty {
                Text(account.displayName)
            } else {
                Label(account.displayName, image: logo)
            }
        }
    }

    /// A toggle, so the system menu draws the current item's tick on the Mac
    /// as on the iPhone and iPad; choosing an item never unticks it.
    private func item(_ title: String, ticked: Bool, action: @escaping () -> Void) -> some View {
        Toggle(title, isOn: Binding(get: { ticked }, set: { _ in action() }))
    }
}

extension AgentModelChoices {
    /// Whether the connection's model list leaves out the agent's model, as
    /// when the provider has dropped it since the agent was saved. No list
    /// read says nothing.
    nonisolated static func isUnlisted(model: String, models: [ProviderInitializationStatus.ModelMetadata]) -> Bool {
        guard !model.isEmpty, !models.isEmpty else { return false }
        return !models.contains { $0.id == model }
    }

    /// What a list says an agent runs on: its model, by its plain name once
    /// its connection's models are read and by its id until then, and its
    /// connection, by the provider's name where the connection is not
    /// among the person's. An agent of the person's own (Hermes, OpenClaw
    /// through its Gateway) runs its turns itself, whatever model is
    /// stored with it: the connection alone.
    func runsOnLine(for role: Role) -> String {
        let provider = role.provider ?? ""
        let models = models(for: role.providerAccountId, provider: provider)
        let model: String = if runsItself(accountId: role.providerAccountId, provider: provider) {
            ""
        } else if provider.lowercased() == "mlx", let active = models.first {
            // On this device the model that is active answers, whichever
            // was stored with the agent.
            active.id
        } else {
            role.model ?? ""
        }
        return Self.modelLine(
            model: model,
            models: models,
            connection: connectionName(accountId: role.providerAccountId, provider: provider)
        )
    }

    /// A connection's name as the person gave it; the provider's name
    /// where the connection is not among the person's (or not read yet).
    func connectionName(accountId: String?, provider: String) -> String {
        account(accountId)?.displayName ?? (provider.isEmpty ? "" : providerDisplayName(slug: provider))
    }

    /// Reads the connections and, for those `agents` run on, their models,
    /// which name the models in a list's rows: each connection's at the
    /// same time, so a slow provider keeps only its own rows waiting. What
    /// cannot be read leaves the rows with the models' ids.
    func loadModelNames(for agents: [Role]) async {
        guard await (try? loadAccounts()) != nil else { return }
        let unread = Set(agents.compactMap(\.providerAccountId)).filter { id in
            guard models(for: id).isEmpty, let account = account(id) else { return false }
            return !runsItself(accountId: id, provider: account.provider)
        }
        await withTaskGroup(of: Void.self) { reads in
            for id in unread {
                reads.addTask { await self.loadModels(for: id) }
            }
        }
    }

    /// "GPT-6 Luna · OpenAI": the model's plain name, else its id, and the
    /// connection it runs on. The connection alone when the agent has no
    /// model.
    nonisolated static func modelLine(
        model: String,
        models: [ProviderInitializationStatus.ModelMetadata],
        connection: String
    ) -> String {
        if model.isEmpty { return connection }
        let name = models.first { $0.id == model }?.name ?? model
        return connection.isEmpty ? name : "\(name) · \(connection)"
    }
}
