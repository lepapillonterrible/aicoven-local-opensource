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
