internal import Combine
import SwiftUI

/// The person's AI connections and each one's models, for an agent's Runs
/// on menu. Models are kept per connection, so a read that finishes after
/// the person picked another connection lands under its own and never
/// replaces the newer one's list. A connection's models are read once at
/// a time: whoever asks while a read is under way waits for that one. What it holds is one account's: a read
/// that lands after another account signed in is dropped, and what was
/// read for an account is shown only while that account is signed in.
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

    /// What was read, and the account it was read for.
    private struct Held {
        var account: String
        var accounts: [ProviderAccount] = []
        var accountsLoaded = false
        var modelsByAccount: [String: [ProviderInitializationStatus.ModelMetadata]] = [:]
        var withGateway: Set<String> = []
    }

    @Published private var held: Held

    /// What is held, while the account it was read for is the one signed
    /// in: nothing of it once another is.
    private var shown: Held {
        let account = signedIn()
        return held.account == account ? held : Held(account: account)
    }

    var accounts: [ProviderAccount] {
        shown.accounts
    }

    /// Whether `accounts` is the person's list, as against not read yet or
    /// a read that failed.
    var accountsLoaded: Bool {
        shown.accountsLoaded
    }

    /// The OpenClaw connections that name a Gateway: their turns are run
    /// by the agent there, not by a model here.
    var withGateway: Set<String> {
        shown.withGateway
    }

    /// The reads of connections' models that are under way, by the account
    /// they are for and the connection.
    private var modelReads: [String: Task<Void, Never>] = [:]
    /// Counts the reads of the connections, so only the newest one applies.
    private var accountLoads = 0
    private let source: Source
    private let signedIn: () -> String

    init(source: Source = .stored, signedIn: @escaping () -> String = { UserScope.currentUserID }) {
        self.source = source
        self.signedIn = signedIn
        held = Held(account: signedIn())
    }

    /// Makes what is held the signed-in account's: what was read for
    /// another is dropped.
    private func holdForTheSignedInAccount() {
        let account = signedIn()
        if held.account != account { held = Held(account: account) }
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
        holdForTheSignedInAccount()
        held.accounts = read
        held.withGateway = gateways
        held.accountsLoaded = true
    }

    func account(_ id: String?) -> ProviderAccount? {
        guard let id else { return nil }
        return accounts.first { $0.id == id }
    }

    func models(for accountId: String?) -> [ProviderInitializationStatus.ModelMetadata] {
        guard let accountId else { return [] }
        return shown.modelsByAccount[accountId] ?? []
    }

    /// Asks the connection's provider for its models, and returns once
    /// they are read. One read of a connection runs at a time: asked again
    /// meanwhile, this waits for the read under way, so everyone who asked
    /// finds the list it brought. A read that fails or lists nothing keeps
    /// whatever list the connection already had, and one that finishes
    /// after another account signed in leaves the list alone.
    func loadModels(for accountId: String) async {
        let account = signedIn()
        let key = "\(account) \(accountId)"
        if let underWay = modelReads[key] {
            await underWay.value
            return
        }
        let read = Task {
            guard let models = try? await source.models(accountId), !models.isEmpty, signedIn() == account else { return }
            holdForTheSignedInAccount()
            held.modelsByAccount[accountId] = models
        }
        modelReads[key] = read
        await read.value
        modelReads[key] = nil
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
}
