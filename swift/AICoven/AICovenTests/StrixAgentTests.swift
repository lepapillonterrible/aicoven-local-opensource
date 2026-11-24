@testable import AICoven
import XCTest

/// Strix is saved as the agent form shows it, as the account that pressed Save.
final class StrixAgentTests: XCTestCase {
    private let defaults = UserDefaults.standard
    private var account = ""
    private var saved: [(String, Any?)] = []

    private func key(_ name: String) -> String {
        UserScope.scopedKey(name, for: account)
    }

    override func setUp() async throws {
        try await super.setUp()
        account = await UserScope.currentUserID
        let names = [
            "strix_settings.v1", "llm_provider", "anthropic_model", "gemini_model", "openai_model", "ollama_model", "openclaw_model",
            "openrouter_model", "openai_compatible_model", "hermes_model", "mlx_model", "hermes_model_connections_converted.v1",
        ]
        saved = names.map { (key($0), defaults.object(forKey: key($0))) }
        names.forEach { defaults.removeObject(forKey: key($0)) }
        // Nothing stored is taken for the old Hermes model connections.
        defaults.set(true, forKey: key("hermes_model_connections_converted.v1"))
    }

    override func tearDown() async throws {
        saved.forEach { defaults.set($0.1, forKey: $0.0) }
        try await super.tearDown()
    }

    private func strix(
        instructions: String = "You plan the week.", provider: String = "anthropic", model: String = "claude-sonnet-4-6",
        temperature: Double? = 0.4, maxTokens: Int? = 3000, mostSteps: Int? = 12
    ) -> AgentSaving {
        AgentSaving(
            name: "Strix", iconSymbol: "sparkles", iconTint: nil, description: "", instructions: instructions,
            provider: provider, model: model, providerAccountId: provider.isEmpty ? nil : "acct",
            temperature: temperature, maxTokens: maxTokens, mostSteps: mostSteps,
            needsModel: !["hermes", "mlx"].contains(provider), needsConnection: false
        )
    }

    func testStrixIsSavedAsTheFormShowsIt_andItsTurnsAreRoutedByIt() async throws {
        let saved = try await StrixSettingsService.shared.save(strix(), as: account)

        XCTAssertEqual(saved.systemPrompt, "You plan the week.")
        XCTAssertEqual([saved.provider, saved.model, saved.providerAccountId], ["anthropic", "claude-sonnet-4-6", "acct"])
        XCTAssertEqual(saved.temperature, 0.4)
        XCTAssertEqual(saved.maxTokens, 3000)
        XCTAssertEqual(saved.autonomousMaxSteps, 12)
        // What is stored is what was given back, and what a turn reads.
        let stored = try XCTUnwrap(StrixSettingsService.stored(of: account))
        XCTAssertEqual([stored.systemPrompt, stored.provider, stored.model], ["You plan the week.", "anthropic", "claude-sonnet-4-6"])
        XCTAssertEqual(AgentTurnSettings(ofStrix: stored), AgentTurnSettings(temperature: 0.4, maxTokens: 3000, mostSteps: 12))
        XCTAssertEqual(defaults.string(forKey: key("llm_provider")), "anthropic")
        XCTAssertEqual(defaults.string(forKey: key("anthropic_model")), "claude-sonnet-4-6")
    }

    func testStrixsModelIsKeptWhereATurnReadsItsProvidersModel() async throws {
        for (provider, model, readFrom) in [
            ("openai", "gpt-4o", "openai_model"), ("google", "gemini-3.5-flash", "gemini_model"), ("ollama", "llama3.2", "ollama_model"),
            ("openclaw", "openai/gpt-4o", "openclaw_model"), ("openrouter", "vendor/model", "openrouter_model"),
            ("openai_compatible", "served", "openai_compatible_model"),
        ] {
            _ = try await StrixSettingsService.shared.save(strix(provider: provider, model: model), as: account)
            XCTAssertEqual(defaults.string(forKey: key("llm_provider")), provider)
            XCTAssertEqual(defaults.string(forKey: key(readFrom)), model, provider)
        }
        // Nothing of an Ollama model was put where OpenAI's is read.
        XCTAssertEqual(defaults.string(forKey: key("openai_model")), "gpt-4o")

        // Hermes, and a model on this device, keep no model here.
        for provider in ["hermes", "mlx"] {
            _ = try await StrixSettingsService.shared.save(strix(provider: provider, model: ""), as: account)
            XCTAssertEqual(defaults.string(forKey: key("llm_provider")), provider)
            XCTAssertNil(defaults.string(forKey: key("\(provider)_model")))
        }
    }

    func testStrixIsSavedOnThisDeviceWithNoModelActiveThere() async throws {
        let saved = try await StrixSettingsService.shared.save(strix(provider: "mlx", model: ""), as: account)
        XCTAssertEqual(saved.provider, "mlx")
        XCTAssertNil(saved.model, "None is kept: the model active on this device answers")
        XCTAssertEqual(defaults.string(forKey: key("llm_provider")), "mlx")

        // Instructions that say nothing are none.
        let blank = try await StrixSettingsService.shared.save(strix(instructions: " \n\n "), as: account)
        XCTAssertNil(blank.systemPrompt)
    }

    func testEmptiedInstructionsAreCleared_andASettingTheFormDidNotShowStaysAsStored() async throws {
        _ = try await StrixSettingsService.shared.save(strix(), as: account)

        let saved = try await StrixSettingsService.shared.save(
            strix(instructions: "", temperature: nil, maxTokens: nil, mostSteps: nil), as: account
        )

        XCTAssertNil(saved.systemPrompt)
        XCTAssertEqual(saved.temperature, 0.4)
        XCTAssertEqual(saved.maxTokens, 3000)
        XCTAssertEqual(saved.autonomousMaxSteps, 12)
    }

    func testStrixsInstructionsAreSavedBeforeThereIsAnyConnection_andKeepWhatItRunsOn() async throws {
        // No connection yet: only the instructions.
        let first = try await StrixSettingsService.shared.save(
            strix(instructions: "Be brief.", provider: "", model: "", temperature: nil, maxTokens: nil, mostSteps: nil), as: account
        )
        XCTAssertEqual(first.systemPrompt, "Be brief.")
        XCTAssertNil(first.provider)
        XCTAssertNil(defaults.string(forKey: key("llm_provider")))

        // With what it runs on stored, a save that names none leaves it.
        _ = try await StrixSettingsService.shared.save(strix(), as: account)
        let later = try await StrixSettingsService.shared.save(strix(instructions: "Be brief.", provider: "", model: ""), as: account)
        XCTAssertEqual([later.provider, later.model], ["anthropic", "claude-sonnet-4-6"])

        // An agent of a coven is not saved with nothing to run on.
        var agent = strix(provider: "", model: "")
        agent.needsConnection = true
        XCTAssertNil(agent.storable)
    }

    func testStrixsDraftIsItsSettings_withTheAppsOwnWhereNoneAreStored() {
        let stored = LocalStrixSettings(
            systemPrompt: "You plan the week.", model: "claude-sonnet-4-6", provider: "Anthropic", providerAccountId: "acct",
            autonomousMaxSteps: 12, temperature: 0.4, maxTokens: 3000
        )
        let draft = AgentDraft(strix: stored, appSteps: 5)
        XCTAssertEqual([draft.name, draft.iconSymbol], ["Strix", "sparkles"])
        XCTAssertEqual(draft.instructions, "You plan the week.")
        XCTAssertEqual([draft.accountId, draft.provider, draft.model], ["acct", "anthropic", "claude-sonnet-4-6"])
        XCTAssertEqual(draft.temperature, 0.4)
        XCTAssertEqual([draft.maxTokens, draft.maxSteps], ["3000", "12"])

        // Nothing stored: what Strix's turns have been given so far.
        let fresh = AgentDraft(strix: LocalStrixSettings(), appSteps: 5)
        XCTAssertEqual(fresh.temperature, 0.7)
        XCTAssertEqual([fresh.maxTokens, fresh.maxSteps], ["4096", "5"])
        XCTAssertEqual(fresh.instructions, "")
        XCTAssertNil(fresh.accountId)
        XCTAssertEqual(AgentDraft(strix: LocalStrixSettings(autonomousMaxSteps: 500), appSteps: 5).maxSteps, "100")
    }

    func testStrixsFormSavesWithNoConnection_andAnAgentsDoesNot() throws {
        var draft = AgentDraft(strix: LocalStrixSettings(systemPrompt: "Be brief."), appSteps: 5)
        XCTAssertNil(draft.saving(usesTemperature: false, usesMaxTokens: false, usesSteps: true), "An agent's form needs a connection")

        let saving = try XCTUnwrap(draft.saving(usesTemperature: false, usesMaxTokens: false, usesSteps: true, needsConnection: false))
        XCTAssertEqual(saving.instructions, "Be brief.")
        XCTAssertEqual([saving.provider, saving.model], ["", ""], "What it runs on is left as stored")
        XCTAssertNil(saving.providerAccountId)
        XCTAssertEqual(saving.mostSteps, 5)

        // Strix on a connection with no model named (none listed yet, and none to type without the upgrade):
        // with what it runs on left out of the save, the rest of the form saves.
        var unnamed = AgentDraft(strix: LocalStrixSettings(systemPrompt: "Be brief.", provider: "anthropic", providerAccountId: "acct"), appSteps: 5)
        XCTAssertNil(unnamed.saving(usesTemperature: true, usesMaxTokens: true, usesSteps: true, needsConnection: false))
        unnamed.accountId = nil
        let kept = try XCTUnwrap(unnamed.saving(usesTemperature: true, usesMaxTokens: true, usesSteps: true, needsConnection: false))
        XCTAssertEqual([kept.provider, kept.model], ["", ""], "What it runs on stays as stored")
        XCTAssertEqual(kept.temperature, 0.7)

        // With a connection chosen it is saved as an agent is: a model's connection needs a model.
        draft.accountId = "acct"
        draft.provider = "anthropic"
        XCTAssertNil(draft.saving(usesTemperature: true, usesMaxTokens: true, usesSteps: true, needsConnection: false))
        // A connection to models on this device needs none named: the one active there answers.
        draft.provider = "mlx"
        let onDevice = try XCTUnwrap(
            draft.saving(usesTemperature: false, usesMaxTokens: true, usesSteps: true, needsModel: false, needsConnection: false)
        )
        XCTAssertEqual([onDevice.provider, onDevice.model, onDevice.providerAccountId], ["mlx", "", "acct"])
        draft.provider = "anthropic"
        draft.model = "claude-sonnet-4-6"
        let chosen = try XCTUnwrap(draft.saving(usesTemperature: true, usesMaxTokens: true, usesSteps: true, needsConnection: false))
        XCTAssertEqual([chosen.provider, chosen.model, chosen.providerAccountId], ["anthropic", "claude-sonnet-4-6", "acct"])
    }

    @MainActor
    func testStrixIsListedAsAnAgentIs() async {
        let row = StrixAgentsView.row(
            for: LocalStrixSettings(systemPrompt: "You plan the week.\nBe brief.", model: "claude-sonnet-4-6", provider: "anthropic", providerAccountId: "acct")
        )
        XCTAssertEqual(row.name, "Strix")
        XCTAssertEqual(row.iconSymbol, "sparkles")
        XCTAssertEqual(CovenAgentsView.instructionsLine(row.systemPrompt), "You plan the week.")
        XCTAssertEqual([row.provider, row.model, row.providerAccountId], ["anthropic", "claude-sonnet-4-6", "acct"])
        // The line that says what it runs on, before the connections are read and for Hermes.
        let choices = AgentModelChoices(source: .init(accounts: { [] }, models: { _ in [] }, hasGateway: { _ in false }), signedIn: { "ada" })
        XCTAssertEqual(choices.runsOnLine(for: row), "claude-sonnet-4-6 · Anthropic")
        let onHermes = StrixAgentsView.row(for: LocalStrixSettings(model: "hermes", provider: "hermes"))
        XCTAssertEqual(choices.runsOnLine(for: onHermes), "Hermes", "An agent of the person's own names no model")
        XCTAssertEqual(choices.runsOnLine(for: StrixAgentsView.row(for: LocalStrixSettings())), "")
        /// With no connection stored, Strix's is the first of its provider's, as its form takes it.
        func connection(_ id: String, _ provider: String) -> ProviderAccount {
            ProviderAccount(
                id: id, userId: nil, provider: provider, accountName: nil, displayName: provider,
                status: "healthy", scopes: [], defaultModel: nil, baseURL: nil, isHealthy: true,
                lastHealthCheck: nil, lastHealthCheckAt: nil, quotaHint: nil, createdAt: nil
            )
        }
        let connections = [connection("a", "openai"), connection("b", "anthropic"), connection("c", "anthropic")]
        let unstored = StrixAgentsView.row(for: LocalStrixSettings(model: "claude-sonnet-4-6", provider: "Anthropic"), among: connections)
        XCTAssertEqual(unstored.providerAccountId, "b")
        XCTAssertEqual(StrixAgentsView.row(for: LocalStrixSettings(providerAccountId: "c"), among: connections).providerAccountId, "c")
        XCTAssertNil(StrixAgentsView.row(for: LocalStrixSettings(), among: connections).providerAccountId)
        // Steps stored as no number of steps are shown as the fewest there can be, so the form still saves.
        XCTAssertEqual(AgentDraft(strix: LocalStrixSettings(autonomousMaxSteps: 0), appSteps: 5).maxSteps, "1")
        // Freed inside a task: a main-actor object released outside one
        // aborts on macOS 15 (issue #61).
        await Task.yield()
    }

    /// Who is signed in, for a service of the test's own. Sendable by hand: read and written under its lock.
    private final class SignedIn: @unchecked Sendable {
        private let lock = NSLock()
        private var account: String

        init(_ account: String) {
            self.account = account
        }

        var now: String {
            get { lock.withLock { account } }
            set { lock.withLock { account = newValue } }
        }
    }

    func testStrixsSettingsAreNotKeptForAnotherAccountThatSignsInWhileTheConnectionsAreLookedUp() async throws {
        let ada = "strix-test-ada-\(UUID().uuidString)", grace = "strix-test-grace-\(UUID().uuidString)"
        let keys = [ada, grace].flatMap { account in ["strix_settings.v1", "llm_provider", "anthropic_model"].map { UserScope.scopedKey($0, for: account) } }
        addTeardownBlock { keys.forEach { UserDefaults.standard.removeObject(forKey: $0) } }
        // Ada has instructions and nothing to run on yet, so her connections are looked up.
        try defaults.set(JSONEncoder().encode(LocalStrixSettings(systemPrompt: "Ada's own instructions.")), forKey: keys[0])
        let signedIn = SignedIn(ada)
        let service = StrixSettingsService(
            signedIn: { signedIn.now },
            firstConnection: {
                // Grace signs in while they are looked up.
                signedIn.now = grace
                return (provider: "anthropic", defaultModel: "claude-sonnet-4-6")
            }
        )

        do {
            _ = try await service.loadPersonalStrix()
            XCTFail("Nothing is given once another account is signed in")
        } catch RepositoryError.accountChanged {}

        XCTAssertNil(StrixSettingsService.stored(of: grace), "Nothing of Ada's is kept as Grace's")
        XCTAssertNil(defaults.string(forKey: UserScope.scopedKey("llm_provider", for: grace)))
        XCTAssertNil(StrixSettingsService.stored(of: ada)?.provider, "Nor are Grace's connections kept as Ada's")
        XCTAssertEqual(StrixSettingsService.stored(of: ada)?.systemPrompt, "Ada's own instructions.")

        // With nobody else signing in, what Strix runs on is taken from the first connection, for the account that asked.
        signedIn.now = ada
        let calm = StrixSettingsService(signedIn: { signedIn.now }, firstConnection: { (provider: "anthropic", defaultModel: "claude-sonnet-4-6") })
        let loaded = try await calm.loadPersonalStrix()
        XCTAssertEqual([loaded.systemPrompt, loaded.provider, loaded.model], ["Ada's own instructions.", "anthropic", "claude-sonnet-4-6"])
        XCTAssertEqual(StrixSettingsService.stored(of: ada)?.provider, "anthropic")
        XCTAssertEqual(defaults.string(forKey: UserScope.scopedKey("anthropic_model", for: ada)), "claude-sonnet-4-6")
        XCTAssertNil(StrixSettingsService.stored(of: grace))

        // What is saved while the connections are looked up is kept: the lookup adds only what Strix still lacks.
        let adaKey = UserScope.scopedKey("strix_settings.v1", for: ada)
        try defaults.set(JSONEncoder().encode(LocalStrixSettings(systemPrompt: "Old instructions.")), forKey: adaKey)
        let slow = StrixSettingsService(signedIn: { signedIn.now }, firstConnection: {
            let saved = LocalStrixSettings(systemPrompt: "Written meanwhile.")
            UserDefaults.standard.set(try? JSONEncoder().encode(saved), forKey: adaKey)
            return (provider: "anthropic", defaultModel: "claude-sonnet-4-6")
        })
        let afterwards = try await slow.loadPersonalStrix()
        XCTAssertEqual([afterwards.systemPrompt, afterwards.provider, afterwards.model], ["Written meanwhile.", "anthropic", "claude-sonnet-4-6"])
        XCTAssertEqual(StrixSettingsService.stored(of: ada)?.systemPrompt, "Written meanwhile.")

        // A model is looked up only for a provider that names one, and only from a connection of that provider.
        let hermesKey = UserScope.scopedKey("strix_settings.v1", for: ada)
        try defaults.set(JSONEncoder().encode(LocalStrixSettings(provider: "hermes")), forKey: hermesKey)
        let onHermes = try await calm.loadPersonalStrix()
        XCTAssertNil(onHermes.model, "Hermes names no model: none of another provider's is put beside it")
        try defaults.set(JSONEncoder().encode(LocalStrixSettings(provider: "openai")), forKey: hermesKey)
        let onOpenAI = try await calm.loadPersonalStrix()
        XCTAssertNil(onOpenAI.model, "The first connection is Anthropic's: its model is not OpenAI's")
        try defaults.set(JSONEncoder().encode(LocalStrixSettings(provider: "Anthropic")), forKey: hermesKey)
        let onAnthropic = try await calm.loadPersonalStrix()
        XCTAssertEqual(onAnthropic.model, "claude-sonnet-4-6")

        // A save is that account's too, whoever is signed in by the time it is written.
        signedIn.now = grace
        do {
            _ = try await calm.save(strix(), as: ada)
            XCTFail("Nothing is saved as an account that is no longer signed in")
        } catch RepositoryError.accountChanged {}
        XCTAssertNil(StrixSettingsService.stored(of: grace))
    }

    func testNothingIsSavedAsAnotherAccount_orOfWhatIsNotSomethingToSave() async throws {
        _ = try await StrixSettingsService.shared.save(strix(), as: account)

        do {
            _ = try await StrixSettingsService.shared.save(strix(instructions: "Another's"), as: "someone-else")
            XCTFail("Nothing is saved as an account that is not signed in")
        } catch RepositoryError.accountChanged {}
        do {
            _ = try await StrixSettingsService.shared.save(strix(temperature: 9), as: account)
            XCTFail("A temperature out of range is not saved")
        } catch CovenRepositoryError.agentIncomplete {}
        do {
            _ = try await StrixSettingsService.shared.save(strix(model: ""), as: account)
            XCTFail("A model's connection needs a model")
        } catch CovenRepositoryError.agentIncomplete {}

        XCTAssertEqual(StrixSettingsService.stored(of: account)?.systemPrompt, "You plan the week.")
        XCTAssertNil(StrixSettingsService.stored(of: "someone-else"))
    }
}
