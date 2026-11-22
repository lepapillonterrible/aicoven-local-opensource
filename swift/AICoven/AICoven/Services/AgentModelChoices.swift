internal import Combine
import SwiftUI

/// The person's AI connections and each one's models, for an agent's Runs
/// on menu. Models are kept per connection, so a read that finishes after
/// the person picked another connection lands under its own and never
/// replaces the newer one's list. What it holds is one account's: a read
/// that lands after another account signed in is dropped.
@MainActor
final class AgentModelChoices: ObservableObject {
    /// Where the connections and their models are read from.
    struct Source {
        var accounts: () async throws -> [ProviderAccount]
        /// A connection's models, asked of its provider.
        var models: (_ accountId: String) async throws -> [ProviderInitializationStatus.ModelMetadata]
        /// Whether a connection names an OpenClaw Gateway.
        var hasGateway: (_ accountId: String) async -> Bool

        static let stored = Source(
            accounts: { try await ProviderAccountService.shared.loadProviderAccounts() },
            models: { try await ProviderAccountService.shared.getInitializationStatus(accountId: $0).modelMetadata },
            hasGateway: { await (try? ProviderAccountService.shared.gatewayAddress(forAccount: $0)) != nil }
        )
    }

    @Published private(set) var accounts: [ProviderAccount] = []
    /// Whether `accounts` is the person's list, as against not read yet or
    /// a read that failed.
    @Published private(set) var accountsLoaded = false
    @Published private(set) var modelsByAccount: [String: [ProviderInitializationStatus.ModelMetadata]] = [:]
    /// The OpenClaw connections that name a Gateway: their turns are run
    /// by the agent there, not by a model here.
    @Published private(set) var withGateway: Set<String> = []

    /// Counts each connection's model reads, so only the newest one applies.
    private var modelReads: [String: Int] = [:]
    /// Counts the reads of the connections, so only the newest one applies.
    private var accountLoads = 0
    private let source: Source
    private let signedIn: () -> String

    init(source: Source = .stored, signedIn: @escaping () -> String = { UserScope.currentUserID }) {
        self.source = source
        self.signedIn = signedIn
    }

    /// Reads the person's connections. A read that finishes after a newer
    /// one began, or after another account signed in, changes nothing.
    func loadAccounts() async throws {
        accountLoads += 1
        let load = accountLoads
        let account = signedIn()
        let read = try await source.accounts()
        var gateways: Set<String> = []
        for connection in read where connection.provider.lowercased() == "openclaw" {
            if await source.hasGateway(connection.id) { gateways.insert(connection.id) }
        }
        guard load == accountLoads, signedIn() == account else { return }
        accounts = read
        withGateway = gateways
        accountsLoaded = true
    }

    func account(_ id: String?) -> ProviderAccount? {
        guard let id else { return nil }
        return accounts.first { $0.id == id }
    }

    func models(for accountId: String?) -> [ProviderInitializationStatus.ModelMetadata] {
        guard let accountId else { return [] }
        return modelsByAccount[accountId] ?? []
    }

    /// Asks the connection's provider for its models. A read that fails or
    /// lists nothing keeps whatever list the connection already had, and
    /// one that finishes after a newer read of the same connection began,
    /// or after another account signed in, leaves the list alone.
    func loadModels(for accountId: String) async {
        modelReads[accountId, default: 0] += 1
        let read = modelReads[accountId]
        let account = signedIn()
        guard let models = try? await source.models(accountId), !models.isEmpty,
              modelReads[accountId] == read, signedIn() == account else { return }
        modelsByAccount[accountId] = models
    }

    /// The connection a new agent starts on: the one of Strix's provider,
    /// else the first that is healthy, else the first.
    func newAgentDefault(strixProvider: String?) -> ProviderAccount? {
        let strix = strixProvider?.lowercased()
        return accounts.first { strix != nil && $0.provider.lowercased() == strix }
            ?? accounts.first { $0.status == "healthy" }
            ?? accounts.first
    }

    // MARK: - Which settings an agent on a connection uses

    /// Whether an agent on this connection is run by an agent of the
    /// person's own (Hermes, or OpenClaw through its Gateway): it takes its
    /// own steps, needs no model chosen here, and is sent none of the
    /// settings under Advanced.
    func runsItself(accountId: String?, provider: String) -> Bool {
        AgentTurnSettings.runsItself(provider: provider, hasGateway: accountId.map(withGateway.contains) ?? false)
    }

    func usesTemperature(accountId: String?, provider: String, model: String) -> Bool {
        !runsItself(accountId: accountId, provider: provider) && AgentTurnSettings.usesTemperature(provider: provider, model: model)
    }

    func usesMaxTokens(accountId: String?, provider: String) -> Bool {
        !runsItself(accountId: accountId, provider: provider) && AgentTurnSettings.usesMaxTokens(provider: provider)
    }

    func usesSteps(accountId: String?, provider: String) -> Bool {
        !runsItself(accountId: accountId, provider: provider)
    }

    /// Whether the connection's model list leaves out the agent's model, as
    /// when the provider has dropped it since the agent was saved. No list
    /// read says nothing.
    nonisolated static func isUnlisted(model: String, models: [ProviderInitializationStatus.ModelMetadata]) -> Bool {
        guard !model.isEmpty, !models.isEmpty else { return false }
        return !models.contains { $0.id == model }
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
