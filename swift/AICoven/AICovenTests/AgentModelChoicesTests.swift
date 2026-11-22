@testable import AICoven
import XCTest

/// The connections and models an agent's Runs on menu offers.
@MainActor
final class AgentModelChoicesTests: XCTestCase {
    /// A read that a test lets through when it chooses.
    private actor Gate {
        private var waiting: [CheckedContinuation<Void, Never>] = []
        private var arrivals: [CheckedContinuation<Void, Never>] = []
        private var count = 0

        /// Waits until the test opens the gate.
        func pass() async {
            count += 1
            arrivals.forEach { $0.resume() }
            arrivals = []
            await withCheckedContinuation { waiting.append($0) }
        }

        /// Returns once `number` reads are waiting.
        func arrived(_ number: Int) async {
            while count < number {
                await withCheckedContinuation { arrivals.append($0) }
            }
        }

        func openFirst() {
            if !waiting.isEmpty { waiting.removeFirst().resume() }
        }

        func openLast() {
            if !waiting.isEmpty { waiting.removeLast().resume() }
        }
    }

    private func account(_ id: String, _ provider: String, status: String = "healthy") -> ProviderAccount {
        ProviderAccount(
            id: id, userId: nil, provider: provider, accountName: nil, displayName: provider,
            status: status, scopes: [], defaultModel: nil, baseURL: nil, isHealthy: true,
            lastHealthCheck: nil, lastHealthCheckAt: nil, quotaHint: nil, createdAt: nil
        )
    }

    private func model(_ id: String) -> ProviderInitializationStatus.ModelMetadata {
        ProviderInitializationStatus.ModelMetadata(id: id, name: nil, provider: nil, contextLength: nil)
    }

    private func choices(
        accounts: [ProviderAccount],
        models: @escaping (String) async throws -> [ProviderInitializationStatus.ModelMetadata] = { _ in [] },
        gateways: Set<String> = [],
        signedIn: @escaping () -> String = { "ada" }
    ) -> AgentModelChoices {
        AgentModelChoices(
            source: .init(accounts: { accounts }, models: models, hasGateway: { gateways.contains($0) }),
            signedIn: signedIn
        )
    }

    func testTheConnectionsAreRead_withWhichOpenClawOnesNameAGateway() async throws {
        let choices = choices(
            accounts: [account("a", "anthropic"), account("claw", "openclaw"), account("claw2", "OpenClaw"), account("h", "hermes")],
            gateways: ["claw", "a"]
        )
        XCTAssertFalse(choices.accountsLoaded)

        try await choices.loadAccounts()

        XCTAssertTrue(choices.accountsLoaded)
        XCTAssertEqual(choices.accounts.map(\.id), ["a", "claw", "claw2", "h"])
        XCTAssertEqual(choices.withGateway, ["claw"], "Only an OpenClaw connection is asked for one")
        XCTAssertEqual(choices.account("claw")?.provider, "openclaw")
        XCTAssertNil(choices.account(nil))
        XCTAssertNil(choices.account("gone"))
    }

    func testAReadOfTheConnectionsThatFails_leavesNoList() async {
        struct Unreadable: Error {}
        let choices = AgentModelChoices(
            source: .init(accounts: { throw Unreadable() }, models: { _ in [] }, hasGateway: { _ in false }),
            signedIn: { "ada" }
        )

        do {
            try await choices.loadAccounts()
            XCTFail("A failed read throws")
        } catch {}

        XCTAssertFalse(choices.accountsLoaded, "Not read is not the same as none")
    }

    func testWhatIsReadForOneAccountIsNotShownToAnother() async throws {
        var signedIn = "ada"
        let gate = Gate()
        let choices = AgentModelChoices(
            source: .init(
                accounts: { [weak self] in
                    await gate.pass()
                    return [self?.account("a", "anthropic")].compactMap(\.self)
                },
                models: { [weak self] _ in
                    await gate.pass()
                    return [self?.model("m")].compactMap(\.self)
                },
                hasGateway: { _ in false }
            ),
            signedIn: { signedIn }
        )

        let reading = Task { try await choices.loadAccounts() }
        await gate.arrived(1)
        signedIn = "grace"
        await gate.openFirst()
        try await reading.value
        XCTAssertFalse(choices.accountsLoaded)
        XCTAssertEqual(choices.accounts.count, 0)

        signedIn = "ada"
        let models = Task { await choices.loadModels(for: "a") }
        await gate.arrived(2)
        signedIn = "grace"
        await gate.openFirst()
        await models.value
        XCTAssertEqual(choices.models(for: "a").count, 0)
    }

    func testWhatWasReadForOneAccountIsGoneOnceAnotherIsSignedIn() async throws {
        var signedIn = "ada"
        let choices = choices(
            accounts: [account("claw", "openclaw"), account("a", "anthropic")],
            models: { _ in [self.model("m")] },
            gateways: ["claw"],
            signedIn: { signedIn }
        )
        try await choices.loadAccounts()
        await choices.loadModels(for: "a")
        XCTAssertEqual(choices.accounts.count, 2)
        XCTAssertEqual(choices.models(for: "a").count, 1)

        // Another account signs in: nothing read for the first is shown, before anything is read again.
        signedIn = "grace"
        XCTAssertEqual(choices.accounts.count, 0)
        XCTAssertFalse(choices.accountsLoaded)
        XCTAssertEqual(choices.withGateway, [])
        XCTAssertNil(choices.account("a"))
        XCTAssertNil(choices.newAgentDefault(strixProvider: "anthropic"))
        XCTAssertEqual(choices.models(for: "a").count, 0)
        XCTAssertFalse(choices.runsItself(accountId: "claw", provider: "openclaw"))

        // What the second reads is its own, with none of the first's models under it.
        try await choices.loadAccounts()
        XCTAssertEqual(choices.accounts.count, 2)
        XCTAssertEqual(choices.models(for: "a").count, 0, "The first account's models are not kept under the second")

        // And the first, signed in again, is shown nothing of what was read before.
        signedIn = "ada"
        XCTAssertEqual(choices.accounts.count, 0)
        XCTAssertEqual(choices.models(for: "a").count, 0)
    }

    func testAConnectionsModelsAreKeptUnderIt_andAFailedReadKeepsTheListItHad() async {
        struct Unreachable: Error {}
        var fails = false
        let choices = choices(
            accounts: [],
            models: { id in
                if fails { throw Unreachable() }
                return id == "empty" ? [] : [self.model("\(id)-model")]
            }
        )

        await choices.loadModels(for: "a")
        await choices.loadModels(for: "b")
        await choices.loadModels(for: "empty")
        XCTAssertEqual(choices.models(for: "a").map(\.id), ["a-model"])
        XCTAssertEqual(choices.models(for: "b").map(\.id), ["b-model"])
        XCTAssertEqual(choices.models(for: "empty").count, 0)
        XCTAssertEqual(choices.models(for: nil).count, 0)

        fails = true
        await choices.loadModels(for: "a")
        XCTAssertEqual(choices.models(for: "a").map(\.id), ["a-model"], "A read that fails keeps what was listed")
    }

    func testAConnectionsModelsAreReadOnceAtATime_andEveryoneWhoAskedFindsThem() async {
        let gate = Gate()
        var reads = 0
        let choices = choices(
            accounts: [],
            models: { id in
                reads += 1
                let read = reads
                await gate.pass()
                return [self.model("\(id)-read-\(read)")]
            }
        )

        // The form's own reading of every connection's models, and the person's choice of one of them.
        let first = Task { await choices.loadModels(for: "a") }
        await gate.arrived(1)
        var secondReturned = false
        let second = Task {
            await choices.loadModels(for: "a")
            secondReturned = true
            return choices.models(for: "a").map(\.id)
        }
        // Another connection is read apart from it.
        let other = Task { await choices.loadModels(for: "b") }
        await gate.arrived(2)
        XCTAssertEqual(reads, 2, "One read of a, one of b: the second asking for a started none")
        XCTAssertFalse(secondReturned, "It waits for the read under way")

        await gate.openFirst()
        await first.value
        let found = await second.value
        XCTAssertEqual(found, ["a-read-1"], "Whoever asked meanwhile finds the list the read brought")
        await gate.openFirst()
        await other.value
        XCTAssertEqual(choices.models(for: "b").map(\.id), ["b-read-2"])

        // Once a read has landed, the next asking reads again.
        let again = Task { await choices.loadModels(for: "a") }
        await gate.arrived(3)
        await gate.openFirst()
        await again.value
        XCTAssertEqual(choices.models(for: "a").map(\.id), ["a-read-3"])
    }

    func testANewAgentStartsOnTheConnectionOfStrixsProvider_elseOnAHealthyOne() async throws {
        let choices = choices(accounts: [account("broken", "openai", status: "error"), account("g", "google"), account("a", "Anthropic")])
        try await choices.loadAccounts()

        XCTAssertEqual(choices.newAgentDefault(strixProvider: "anthropic")?.id, "a")
        XCTAssertEqual(choices.newAgentDefault(strixProvider: "openai")?.id, "broken", "Strix's own, as Strix uses it")
        XCTAssertEqual(choices.newAgentDefault(strixProvider: nil)?.id, "g", "The first that is healthy")
        XCTAssertEqual(choices.newAgentDefault(strixProvider: "ollama")?.id, "g")

        let onlyBroken = self.choices(accounts: [account("broken", "openai", status: "error")])
        try await onlyBroken.loadAccounts()
        XCTAssertEqual(onlyBroken.newAgentDefault(strixProvider: nil)?.id, "broken")
        let none = self.choices(accounts: [])
        try await none.loadAccounts()
        XCTAssertNil(none.newAgentDefault(strixProvider: "openai"))
    }

    func testWhichSettingsAnAgentUses_byWhatItRunsOn() async throws {
        let choices = choices(
            accounts: [account("claw", "openclaw"), account("served", "openclaw"), account("h", "hermes"), account("a", "anthropic")],
            gateways: ["claw"]
        )
        try await choices.loadAccounts()

        // An agent of the person's own runs its turns itself: none of the settings reach it.
        for (id, provider) in [("claw", "openclaw"), ("h", "hermes")] {
            XCTAssertTrue(choices.runsItself(accountId: id, provider: provider))
            XCTAssertFalse(choices.usesSteps(accountId: id, provider: provider))
            XCTAssertFalse(choices.usesTemperature(accountId: id, provider: provider, model: "any"))
            XCTAssertFalse(choices.usesMaxTokens(accountId: id, provider: provider))
        }
        // OpenClaw without a Gateway is a server a model answers through.
        XCTAssertFalse(choices.runsItself(accountId: "served", provider: "openclaw"))
        XCTAssertTrue(choices.usesSteps(accountId: "served", provider: "openclaw"))
        XCTAssertTrue(choices.usesTemperature(accountId: "served", provider: "openclaw", model: "any"))
        XCTAssertFalse(choices.usesMaxTokens(accountId: "served", provider: "openclaw"))
        // A model's turn, by its provider and its name.
        XCTAssertTrue(choices.usesSteps(accountId: "a", provider: "anthropic"))
        XCTAssertTrue(choices.usesMaxTokens(accountId: "a", provider: "anthropic"))
        XCTAssertTrue(choices.usesTemperature(accountId: "a", provider: "anthropic", model: "claude-sonnet-4-6"))
        XCTAssertFalse(choices.usesTemperature(accountId: "a", provider: "anthropic", model: "claude-haiku-5-5"))
    }
}
