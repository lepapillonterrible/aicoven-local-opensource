@testable import AICoven
import XCTest

/// What the agent form edits and what saving it stores.
final class AgentDraftTests: XCTestCase {
    func testAnAgentSavesOnlyWithAnAccountAndAModel() {
        var draft = AgentDraft()
        XCTAssertFalse(draft.hasAccountAndModel())

        draft.accountId = "acct_1"
        XCTAssertFalse(draft.hasAccountAndModel(), "no model")

        draft.model = "  "
        XCTAssertFalse(draft.hasAccountAndModel(), "blank model")
        XCTAssertTrue(draft.hasAccountAndModel(needsModel: false), "An agent of the person's own runs its turns itself")

        draft.model = "gpt-5.2"
        XCTAssertTrue(draft.hasAccountAndModel(), "needs no loaded account list, so a failed load does not block a save")
    }

    func testMovingToAnotherAccountNeverKeepsTheOldAccountsModel() {
        var draft = AgentDraft()
        draft.accountId = "acct_openai"
        draft.provider = "openai"
        draft.model = "gpt-4o"

        draft.moveToAccount(account(id: "acct_anthropic", provider: "Anthropic", defaultModel: "claude-sonnet"))
        XCTAssertEqual(draft.accountId, "acct_anthropic")
        XCTAssertEqual(draft.provider, "anthropic")
        XCTAssertEqual(draft.model, "claude-sonnet")

        draft.moveToAccount(account(id: "acct_other", provider: "google", defaultModel: nil))
        XCTAssertEqual(draft.model, "", "no default: none until the account's models load")
        XCTAssertFalse(draft.hasAccountAndModel())
    }

    func testChoosingInRunsOn_takesTheConnectionAndTheModel_andIsCounted() {
        var draft = AgentDraft()
        let anthropic = account(id: "a", provider: "anthropic", defaultModel: "claude-default")
        XCTAssertEqual(draft.choicesMade, 0)

        XCTAssertTrue(draft.choose(anthropic), "The connection changed: its models are to be read")
        XCTAssertEqual([draft.accountId, draft.provider, draft.model], ["a", "anthropic", "claude-default"])
        XCTAssertEqual(draft.choicesMade, 1)

        // Another model of the same connection is a choice too.
        XCTAssertFalse(draft.choose(anthropic, model: "claude-other"))
        XCTAssertEqual(draft.model, "claude-other")
        XCTAssertEqual(draft.choicesMade, 2)

        // Another connection never keeps the old one's model.
        XCTAssertTrue(draft.choose(account(id: "g", provider: "google", defaultModel: nil)))
        XCTAssertEqual(draft.model, "")
        XCTAssertTrue(draft.choose(anthropic, model: "claude-other"))
        XCTAssertEqual([draft.accountId, draft.model], ["a", "claude-other"])
        XCTAssertEqual(draft.choicesMade, 4)
    }

    func testAModelListThatLandsLate_changesNothingThePersonHasChangedSince() {
        let listed = [model("listed-first"), model("listed-second")]
        var draft = AgentDraft()
        draft.choose(account(id: "a", provider: "anthropic", defaultModel: "default"))

        // The list lands with the model as it was when the read began: the first listed takes its place.
        var landed = draft
        landed.takeModels(listed, of: "a", readWhenModelWas: "default")
        XCTAssertEqual(landed.model, "listed-first")

        // A model that is listed stays.
        landed = draft
        landed.model = "listed-second"
        landed.takeModels(listed, of: "a", readWhenModelWas: "listed-second")
        XCTAssertEqual(landed.model, "listed-second")

        // The person typed a model's id under Advanced while the list was read: it stays.
        landed = draft
        landed.model = "typed-by-hand"
        landed.takeModels(listed, of: "a", readWhenModelWas: "default")
        XCTAssertEqual(landed.model, "typed-by-hand")

        // Another connection was chosen meanwhile: its model is not touched.
        landed = draft
        landed.choose(account(id: "g", provider: "google", defaultModel: "default"))
        landed.takeModels(listed, of: "a", readWhenModelWas: "default")
        XCTAssertEqual([landed.accountId, landed.model], ["g", "default"])

        // Nothing listed changes nothing.
        landed = draft
        landed.takeModels([], of: "a", readWhenModelWas: "default")
        XCTAssertEqual(landed.model, "default")
    }

    func testANewAgentStartsOnTheFirstTintNoAgentShows_sandForOneWithNoTintOfItsOwn() {
        func agent(tint: String?) -> Role {
            Role(
                id: UUID().uuidString, covenId: "c", name: "Agent", emoji: nil, description: nil, systemPrompt: nil,
                model: nil, provider: nil, providerAccountId: nil, temperature: nil, maxTokens: nil,
                settings: tint.map {
                    RoleSettings(
                        toolConfig: nil, allowedTools: nil, collaboratorRoleIds: nil, autonomousMode: nil, autonomousMaxSteps: nil,
                        plannerMaxTasks: nil, plannerMaxSeconds: nil, iconSymbol: nil, iconTint: $0
                    )
                },
                createdAt: Date(), updatedAt: Date()
            )
        }
        let first = IconTint.allCases[0], second = IconTint.allCases[1], third = IconTint.allCases[2]
        XCTAssertEqual(first, .warm, "Sand is the first tint, and what an agent with none shows")

        XCTAssertEqual(AgentDraft.startingTint(among: []), first)
        XCTAssertEqual(AgentDraft.startingTint(among: [agent(tint: nil)]), second, "An agent made before agents had tints shows sand")
        XCTAssertEqual(AgentDraft.startingTint(among: [agent(tint: "not-a-tint")]), second)
        XCTAssertEqual(AgentDraft.startingTint(among: [agent(tint: second.rawValue)]), first)
        XCTAssertEqual(AgentDraft.startingTint(among: [agent(tint: nil), agent(tint: second.rawValue)]), third)
    }

    func testAConnectionAddedFromTheFormIsTheOneThatIsNew() {
        let before: Set = ["a", "b"]
        let a = account(id: "a", provider: "anthropic", defaultModel: nil)
        let b = account(id: "b", provider: "openai", defaultModel: nil)
        let c = account(id: "c", provider: "google", defaultModel: nil)
        let d = account(id: "d", provider: "ollama", defaultModel: nil)

        XCTAssertEqual(AgentDraft.added(to: before, in: [a, b, c])?.id, "c")
        XCTAssertNil(AgentDraft.added(to: before, in: [a, b]), "Nothing was added")
        XCTAssertNil(AgentDraft.added(to: before, in: [a, b, c, d]), "Two are new: which was meant is not known")
        XCTAssertEqual(AgentDraft.added(to: before, in: [b, c])?.id, "c", "One removed meanwhile is no matter")
    }

    func testASavedAgentKeepsAModelItsAccountNoLongerLists() {
        let listed = [model("gemini-3.8-flash"), model("gemini-3.5-flash")]
        var draft = AgentDraft()
        draft.accountId = "acct_google"
        draft.provider = "google"
        draft.model = "gemini-2.5-flash"

        draft.takeLoadedModels(listed, isNewAgent: false)
        XCTAssertEqual(draft.model, "gemini-2.5-flash", "only the person changes a saved model")

        draft.model = ""
        draft.takeLoadedModels(listed, isNewAgent: false)
        XCTAssertEqual(draft.model, "gemini-3.8-flash", "a saved agent with no model starts on the list's first")

        draft.model = "gemini-2.0-flash"
        draft.takeLoadedModels(listed, isNewAgent: true)
        XCTAssertEqual(draft.model, "gemini-3.8-flash", "a new agent starts on a model the account lists")

        draft.model = "gemini-3.5-flash"
        draft.takeLoadedModels(listed, isNewAgent: true)
        XCTAssertEqual(draft.model, "gemini-3.5-flash", "a new agent's listed default stays")

        draft.model = ""
        draft.takeLoadedModels([], isNewAgent: false)
        XCTAssertEqual(draft.model, "", "nothing listed: still none")
    }

    func testTheDraftOfASavedAgentIsWhatIsStored() {
        let stored = Role(
            id: "r", covenId: "c", name: "Scout", emoji: "🔍", description: "Reads code", systemPrompt: "You review code.",
            model: "claude-sonnet-4-6", provider: "Anthropic", providerAccountId: "acct", temperature: 0.2, maxTokens: 900,
            settings: RoleSettings(
                toolConfig: nil, allowedTools: nil, collaboratorRoleIds: nil, autonomousMode: nil, autonomousMaxSteps: 12,
                plannerMaxTasks: nil, plannerMaxSeconds: nil, iconSymbol: nil, iconTint: "moss"
            ),
            createdAt: Date(), updatedAt: Date()
        )
        let draft = AgentDraft(role: stored)

        XCTAssertEqual(draft.name, "Scout")
        XCTAssertEqual(draft.iconSymbol, "magnifyingglass", "An agent made when agents had an emoji shows the symbol that replaced it")
        XCTAssertEqual(draft.iconTint, .moss)
        XCTAssertEqual(draft.description, "Reads code")
        XCTAssertEqual(draft.instructions, "You review code.")
        XCTAssertEqual(draft.accountId, "acct")
        XCTAssertEqual(draft.provider, "anthropic")
        XCTAssertEqual(draft.model, "claude-sonnet-4-6")
        XCTAssertEqual(draft.temperature, 0.2)
        XCTAssertEqual(draft.maxTokens, "900")
        XCTAssertEqual(draft.maxSteps, "12")

        // A step count stored beyond what a turn takes shows as the most a turn takes.
        let many = Role(
            id: "r", covenId: "c", name: "Scout", emoji: nil, description: nil, systemPrompt: nil,
            model: "m", provider: "openai", providerAccountId: "acct", temperature: nil, maxTokens: nil,
            settings: RoleSettings(
                toolConfig: nil, allowedTools: nil, collaboratorRoleIds: nil, autonomousMode: nil, autonomousMaxSteps: 500,
                plannerMaxTasks: nil, plannerMaxSeconds: nil
            ),
            createdAt: Date(), updatedAt: Date()
        )
        XCTAssertEqual(AgentDraft(role: many).maxSteps, "100")
        XCTAssertNotNil(AgentDraft(role: many).saving(usesTemperature: true, usesMaxTokens: false, usesSteps: true), "And can be saved")

        // What a new agent starts with, as in the cloud app.
        let new = AgentDraft()
        XCTAssertEqual([new.iconSymbol, new.maxTokens, new.maxSteps], ["cpu", "2000", "30"])
        XCTAssertEqual(new.temperature, 0.7)
        XCTAssertNil(new.iconTint, "Chosen when the agent is made, among the tints its coven's agents do not wear")
    }

    func testSavingStoresTheSettingsUnderAdvancedOnlyWhereTheFormShowsThem() throws {
        var draft = AgentDraft()
        draft.name = "  Scout \n"
        draft.accountId = "acct"
        draft.provider = "Anthropic"
        draft.model = " claude-sonnet-4-6 "
        draft.temperature = 0.4
        draft.maxTokens = "900"
        draft.maxSteps = "12"

        let all = try XCTUnwrap(draft.saving(usesTemperature: true, usesMaxTokens: true, usesSteps: true))
        XCTAssertEqual(all.name, "Scout")
        XCTAssertEqual(all.provider, "anthropic")
        XCTAssertEqual(all.model, "claude-sonnet-4-6")
        XCTAssertEqual(all.providerAccountId, "acct")
        XCTAssertEqual(all.temperature, 0.4)
        XCTAssertEqual(all.maxTokens, 900)
        XCTAssertEqual(all.mostSteps, 12)

        // A setting the agent's turns do not use is not shown, and is left as it is stored.
        let none = try XCTUnwrap(draft.saving(usesTemperature: false, usesMaxTokens: false, usesSteps: false))
        XCTAssertNil(none.temperature)
        XCTAssertNil(none.maxTokens)
        XCTAssertNil(none.mostSteps)

        // A limit that is shown must be a number of at least 1; one that is not shown is not looked at.
        draft.maxTokens = "many"
        XCTAssertNil(draft.saving(usesTemperature: true, usesMaxTokens: true, usesSteps: true))
        XCTAssertNotNil(draft.saving(usesTemperature: true, usesMaxTokens: false, usesSteps: true))
        draft.maxTokens = "900"
        draft.maxSteps = "0"
        XCTAssertNil(draft.saving(usesTemperature: true, usesMaxTokens: true, usesSteps: true))
        XCTAssertNotNil(draft.saving(usesTemperature: true, usesMaxTokens: true, usesSteps: false))
        // The most steps are what a turn takes: 1 to 100, and no more is saved.
        for (steps, saves) in [("1", true), ("100", true), ("101", false), ("-3", false)] {
            draft.maxSteps = steps
            XCTAssertEqual(draft.saving(usesTemperature: true, usesMaxTokens: true, usesSteps: true)?.mostSteps, saves ? Int(steps) : nil, steps)
        }
    }

    func testAnAgentIsSavedOnlyWithANameAndWhatItRunsOn() {
        var draft = AgentDraft()
        draft.accountId = "acct"
        draft.provider = "openai"
        draft.model = "gpt-4o"
        func saves(_ draft: AgentDraft, needsModel: Bool = true) -> Bool {
            draft.saving(usesTemperature: true, usesMaxTokens: false, usesSteps: true, needsModel: needsModel) != nil
        }

        XCTAssertFalse(saves(draft), "no name")
        draft.name = "   "
        XCTAssertFalse(saves(draft), "a blank name")
        draft.name = String(repeating: "a", count: 101)
        XCTAssertFalse(saves(draft), "a name longer than the cloud app keeps")
        draft.name = String(repeating: "a", count: 100)
        XCTAssertTrue(saves(draft))

        draft.accountId = nil
        XCTAssertFalse(saves(draft), "no connection")
        draft.accountId = "acct"
        draft.model = ""
        XCTAssertFalse(saves(draft), "no model")
        draft.provider = "hermes"
        XCTAssertTrue(saves(draft, needsModel: false), "Hermes runs its turns itself, with no model named here")
        draft.provider = ""
        XCTAssertFalse(saves(draft, needsModel: false), "no provider")

        // What reaches the store by another way is held to the same rules.
        let agent = AgentSaving(
            name: "Scout", iconSymbol: "cpu", iconTint: nil, description: "", instructions: "",
            provider: "openai", model: "gpt-4o", providerAccountId: "acct", temperature: 0.7, maxTokens: 2000, mostSteps: 30
        )
        XCTAssertNotNil(agent.storable)
        var changed = agent
        changed.temperature = 2.5
        XCTAssertNil(changed.storable)
        changed = agent
        changed.temperature = -0.1
        XCTAssertNil(changed.storable)
        changed = agent
        changed.maxTokens = 0
        XCTAssertNil(changed.storable)
        changed = agent
        changed.mostSteps = 0
        XCTAssertNil(changed.storable)
        changed = agent
        changed.model = " "
        XCTAssertNil(changed.storable)
    }

    private func model(_ id: String) -> ProviderInitializationStatus.ModelMetadata {
        ProviderInitializationStatus.ModelMetadata(id: id, name: nil, provider: nil, contextLength: nil)
    }

    private func account(id: String, provider: String, defaultModel: String?) -> ProviderAccount {
        ProviderAccount(
            id: id, userId: nil, provider: provider, accountName: nil, displayName: provider,
            status: "healthy", scopes: [], defaultModel: defaultModel, baseURL: nil, isHealthy: true,
            lastHealthCheck: nil, lastHealthCheckAt: nil, quotaHint: nil, createdAt: nil
        )
    }
}
