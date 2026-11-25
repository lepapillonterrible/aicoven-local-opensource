@testable import AICoven
import XCTest

/// What the agent form's Runs on line says.
final class AgentRunsOnTests: XCTestCase {
    func testAModelIsMarkedUnlistedOnlyAgainstAListThatWasRead() {
        let listed = [model("gemini-3.8-flash")]

        XCTAssertTrue(AgentModelChoices.isUnlisted(model: "gemini-2.5-flash", models: listed))
        XCTAssertFalse(AgentModelChoices.isUnlisted(model: "gemini-3.8-flash", models: listed))
        XCTAssertFalse(AgentModelChoices.isUnlisted(model: "gemini-2.5-flash", models: []), "no list read says nothing")
        XCTAssertFalse(AgentModelChoices.isUnlisted(model: "", models: listed), "no model")
    }

    func testTheLineThatSaysWhatAnAgentRunsOn() {
        let listed = [model("gpt-6-luna", name: "GPT-6 Luna")]
        XCTAssertEqual(AgentModelChoices.modelLine(model: "gpt-6-luna", models: listed, connection: "OpenAI"), "GPT-6 Luna · OpenAI")
        XCTAssertEqual(AgentModelChoices.modelLine(model: "typed-by-hand", models: listed, connection: "OpenAI"), "typed-by-hand · OpenAI")
        XCTAssertEqual(AgentModelChoices.modelLine(model: "", models: listed, connection: "Hermes"), "Hermes", "An agent with no model")
        XCTAssertEqual(AgentModelChoices.modelLine(model: "gpt-6-luna", models: listed, connection: ""), "GPT-6 Luna")
    }

    func testAnthropicsListOfModelsIsReadAPageAtATime() throws {
        let first = try JSONDecoder().decode(
            AnthropicModelsPage.self,
            from: Data(#"{"data":[{"id":"claude-a","display_name":"Claude A"},{"id":"claude-b"}],"has_more":true,"last_id":"claude-b"}"#.utf8)
        )
        XCTAssertEqual(first.data?.map(\.id), ["claude-a", "claude-b"])
        XCTAssertEqual(first.data?.first?.display_name, "Claude A")
        XCTAssertEqual(first.next, "claude-b", "There is more: the next page is asked for after the last model of this one")
        let last = try JSONDecoder().decode(AnthropicModelsPage.self, from: Data(#"{"data":[{"id":"claude-c"}],"has_more":false,"last_id":"claude-c"}"#.utf8))
        XCTAssertNil(last.next, "The last page")
        XCTAssertNil(try JSONDecoder().decode(AnthropicModelsPage.self, from: Data("{}".utf8)).next)

        XCTAssertEqual(AnthropicModelsPage.address(after: nil).absoluteString, "https://api.anthropic.com/v1/models?limit=1000")
        XCTAssertEqual(
            AnthropicModelsPage.address(after: "claude-b").absoluteString, "https://api.anthropic.com/v1/models?limit=1000&after_id=claude-b"
        )
    }

    func testEveryPageOfAnthropicsListIsRead_andAListLongerThanIsReadIsNotGivenAsWhole() async throws {
        func page(_ ids: [String], more: Bool) throws -> AnthropicModelsPage {
            let items = ids.map { #"{"id":"\#($0)"}"# }.joined(separator: ",")
            return try JSONDecoder().decode(
                AnthropicModelsPage.self, from: Data(#"{"data":[\#(items)],"has_more":\#(more),"last_id":"\#(ids.last ?? "")"}"#.utf8)
            )
        }
        var askedAfter: [String?] = []

        let all = try await AnthropicModelsPage.all { after in
            askedAfter.append(after)
            switch after {
            case nil: return try page(["a", "b"], more: true)
            case "b": return try page(["c"], more: true)
            default: return try page(["d"], more: false)
            }
        }
        XCTAssertEqual(all.map(\.id), ["a", "b", "c", "d"])
        XCTAssertEqual(askedAfter, [nil, "b", "c"], "Each page is asked for after the last model of the one before")

        // A list that never ends is read no further than the most pages, and is not given.
        var pagesRead = 0
        do {
            _ = try await AnthropicModelsPage.all { _ in
                pagesRead += 1
                return try page(["m\(pagesRead)"], more: true)
            }
            XCTFail("A list longer than is read is not a list")
        } catch {}
        XCTAssertEqual(pagesRead, AnthropicModelsPage.mostPages)

        // Nor is one whose page says there is more without saying after which model.
        do {
            _ = try await AnthropicModelsPage.all { _ in
                try JSONDecoder().decode(AnthropicModelsPage.self, from: Data(#"{"data":[{"id":"a"}],"has_more":true}"#.utf8))
            }
            XCTFail("An unfinished list is not a list")
        } catch {}

        // A page that cannot be read ends the reading.
        struct Unreachable: Error {}
        do {
            _ = try await AnthropicModelsPage.all { _ in throw Unreachable() }
            XCTFail("A page that cannot be read is an error")
        } catch is Unreachable {}
    }

    @MainActor
    func testWhatAListSaysAnAgentRunsOn() async {
        func agent(provider: String?, model: String?, account: String?) -> Role {
            Role(
                id: UUID().uuidString, covenId: "c", name: "Agent", emoji: nil, description: nil, systemPrompt: nil,
                model: model, provider: provider, providerAccountId: account, temperature: nil, maxTokens: nil,
                settings: nil, createdAt: Date(), updatedAt: Date()
            )
        }
        func connection(_ id: String, _ provider: String, named name: String) -> ProviderAccount {
            ProviderAccount(
                id: id, userId: nil, provider: provider, accountName: nil, displayName: name, status: "healthy", scopes: [],
                defaultModel: nil, baseURL: nil, isHealthy: true, lastHealthCheck: nil, lastHealthCheckAt: nil, quotaHint: nil, createdAt: nil
            )
        }
        var modelsRead: [String] = []
        let choices = AgentModelChoices(
            source: .init(
                accounts: { [connection("a", "anthropic", named: "Work key"), connection("claw", "openclaw", named: "My Claw"), connection("h", "hermes", named: "Hermes")] },
                models: { id in
                    modelsRead.append(id)
                    return [self.model("claude-sonnet-4-6", name: "Claude Sonnet 4.6")]
                },
                hasGateway: { $0 == "claw" }
            ),
            signedIn: { "ada" }
        )
        let scout = agent(provider: "anthropic", model: "claude-sonnet-4-6", account: "a")
        let throughAGateway = agent(provider: "openclaw", model: "an-old-model", account: "claw")
        let onHermes = agent(provider: "hermes", model: "hermes", account: "h")

        // Before anything is read: the model's id and the provider's name.
        XCTAssertEqual(choices.runsOnLine(for: scout), "claude-sonnet-4-6 · Anthropic")

        await choices.loadModelNames(for: [scout, throughAGateway, onHermes])

        XCTAssertEqual(choices.runsOnLine(for: scout), "Claude Sonnet 4.6 · Work key", "The model's plain name and the connection's own")
        XCTAssertEqual(choices.runsOnLine(for: throughAGateway), "My Claw", "It runs its turns itself, whatever model is stored with it")
        XCTAssertEqual(choices.runsOnLine(for: onHermes), "Hermes")
        XCTAssertEqual(modelsRead, ["a"], "Only the models of connections a model answers through are read")
        // A connection that is gone, and an agent with nothing stored.
        XCTAssertEqual(choices.runsOnLine(for: agent(provider: "openai", model: "gpt-4o", account: "gone")), "gpt-4o · OpenAI")
        XCTAssertEqual(choices.runsOnLine(for: agent(provider: nil, model: nil, account: nil)), "")
    }

    private func model(_ id: String, name: String? = nil) -> ProviderInitializationStatus.ModelMetadata {
        ProviderInitializationStatus.ModelMetadata(id: id, name: name, provider: nil, contextLength: nil)
    }
}
