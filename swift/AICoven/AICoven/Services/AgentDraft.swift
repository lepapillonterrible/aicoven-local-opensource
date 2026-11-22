import Foundation

/// What the agent form saves of an agent, as the cloud app's form sends it.
nonisolated struct AgentSaving: Equatable {
    var name: String
    var iconSymbol: String
    /// The tint the agent wears. With none, a new agent takes the first
    /// tint none of its coven's agents wears, and a saved one keeps its own.
    var iconTint: IconTint?
    /// Saved as they are: an emptied one clears what was stored.
    var description: String
    var instructions: String
    var provider: String
    var model: String
    var providerAccountId: String?
    /// Each is saved only where the form shows it, which is where the
    /// agent's turns use it; nil leaves what is stored as it is.
    var temperature: Double?
    var maxTokens: Int?
    var mostSteps: Int?
    /// Whether the agent is one a model answers for, and so needs a model
    /// named: not one on Hermes or on OpenClaw through its Gateway, which
    /// are agents of the person's own and run their turns themselves.
    var needsModel = true

    static let longestName = 100
    /// The most tool steps an agent can be given: a turn takes as many as
    /// the agent says, up to this (`AgentTurnSettings`).
    static let mostStepsAllowed = AgentTurnSettings.mostStepsAllowed

    /// The agent as it is stored, by the cloud app's rules: its name
    /// without the space around it, 1 to 100 characters; a provider and,
    /// where a model answers for it, a model; a temperature from 0 to 2;
    /// a longest answer of at least 1. Its tool steps are 1 to 100: what
    /// a turn takes is what is stored. Nil for an agent that is not one
    /// of these, which is not saved.
    var storable: AgentSaving? {
        var stored = self
        stored.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        stored.provider = provider.trimmingCharacters(in: .whitespaces).lowercased()
        stored.model = model.trimmingCharacters(in: .whitespaces)
        guard !stored.name.isEmpty, stored.name.count <= Self.longestName,
              !stored.provider.isEmpty, !stored.model.isEmpty || !needsModel,
              temperature.map({ (0 ... 2).contains($0) }) ?? true,
              maxTokens.map({ $0 >= 1 }) ?? true,
              mostSteps.map({ (1 ... Self.mostStepsAllowed).contains($0) }) ?? true else { return nil }
        return stored
    }
}

/// What the agent form edits, before it is saved.
nonisolated struct AgentDraft: Equatable {
    var name = ""
    var iconSymbol = SymbolDisc.fallbackSymbol
    /// Nil until the coven's unused tint is known or the person picks
    /// one; a new agent saved with none is given one as it is made.
    var iconTint: IconTint?
    var description = ""
    var instructions = ""
    var accountId: String?
    var provider = ""
    var model = ""
    var temperature = 0.7
    var maxTokens = "2000"
    var maxSteps = "30"
    /// How many times something was chosen in Runs on. A connection added
    /// from the form is chosen only if this has not moved meanwhile.
    private(set) var choicesMade = 0

    init() {}

    init(role: Role) {
        name = role.name
        iconSymbol = role.iconSymbol ?? SymbolDisc.fallbackSymbol
        iconTint = role.iconTintValue
        description = role.description ?? ""
        instructions = role.systemPrompt ?? ""
        accountId = role.providerAccountId
        provider = (role.provider ?? "").lowercased()
        model = role.model ?? ""
        temperature = role.temperature ?? 0.7
        maxTokens = String(role.maxTokens ?? 2000)
        // A number stored beyond the most a turn takes shows as the most:
        // that is what the agent's turns take.
        if let steps = role.settings?.autonomousMaxSteps {
            maxSteps = String(min(steps, AgentSaving.mostStepsAllowed))
        }
    }

    /// An agent runs on one account and one model, so it saves only with
    /// both. An agent of the person's own (Hermes, OpenClaw through its
    /// Gateway) runs its turns itself and needs no model (`needsModel`).
    func hasAccountAndModel(needsModel: Bool = true) -> Bool {
        accountId != nil && (!needsModel || !model.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    /// Moves the agent to another account. The old account's model does not
    /// carry over; it starts on the new account's default, or on none until
    /// the account's model list loads.
    mutating func moveToAccount(_ account: ProviderAccount) {
        accountId = account.id
        provider = account.provider.lowercased()
        model = account.defaultModel ?? ""
    }

    /// Chooses a Runs on item: the connection and, when the item was one of
    /// its models, that model. Another connection takes the agent over with
    /// its own default model, never the old connection's. Says whether the
    /// connection changed (its models are then to be read).
    @discardableResult
    mutating func choose(_ account: ProviderAccount, model chosen: String? = nil) -> Bool {
        choicesMade += 1
        let moved = accountId != account.id
        if moved { moveToAccount(account) }
        if let chosen { model = chosen }
        return moved
    }

    /// The model once the models of a connection chosen in the form are
    /// read: the first listed, where the model is not among them. `model`
    /// is what the model was when the read began: a read that lands after
    /// another connection was chosen, or after the model was changed (by
    /// choosing one, or typing its id under Advanced), changes nothing.
    mutating func takeModels(
        _ models: [ProviderInitializationStatus.ModelMetadata], of account: String, readWhenModelWas model: String
    ) {
        guard accountId == account, self.model == model,
              let first = models.first, !models.contains(where: { $0.id == model }) else { return }
        self.model = first.id
    }

    /// The tint a new agent starts with: the first that none of the
    /// coven's agents shows. An agent with no tint of its own shows sand.
    static func startingTint(among agents: [Role]) -> IconTint {
        IconTint.nextUnused(worn: agents.map { ($0.iconTintValue ?? .warm).rawValue })
    }

    /// The connection that is new among `accounts` since `known` were the
    /// person's connections: nil where none is, or more than one.
    static func added(to known: Set<String>, in accounts: [ProviderAccount]) -> ProviderAccount? {
        let new = accounts.filter { !known.contains($0.id) }
        return new.count == 1 ? new[0] : nil
    }

    /// The model once the form's account's list loads. A new agent starts on
    /// a model the account lists. A saved agent keeps the model it has, listed
    /// or not, since only the person changes it; one with none starts on the
    /// first listed model.
    mutating func takeLoadedModels(_ models: [ProviderInitializationStatus.ModelMetadata], isNewAgent: Bool) {
        guard let first = models.first else { return }
        if isNewAgent {
            if !models.contains(where: { $0.id == model }) { model = first.id }
        } else if model.trimmingCharacters(in: .whitespaces).isEmpty {
            model = first.id
        }
    }

    /// What saving the form stores. The settings under Advanced are saved
    /// only where the form shows them (`uses`): the others stay as stored.
    /// Nil where the form cannot be saved: no name, no account or model,
    /// or a limit shown that is not a number of at least 1.
    func saving(usesTemperature: Bool, usesMaxTokens: Bool, usesSteps: Bool, needsModel: Bool = true) -> AgentSaving? {
        guard hasAccountAndModel(needsModel: needsModel) else { return nil }
        let tokens = Int(maxTokens.trimmingCharacters(in: .whitespaces))
        let steps = Int(maxSteps.trimmingCharacters(in: .whitespaces))
        if usesMaxTokens, tokens == nil { return nil }
        if usesSteps, steps == nil { return nil }
        return AgentSaving(
            name: name,
            iconSymbol: iconSymbol,
            iconTint: iconTint,
            description: description,
            instructions: instructions,
            provider: provider,
            model: model,
            providerAccountId: accountId,
            temperature: usesTemperature ? temperature : nil,
            maxTokens: usesMaxTokens ? tokens : nil,
            mostSteps: usesSteps ? steps : nil,
            needsModel: needsModel
        ).storable
    }
}
