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

    private func model(_ id: String, name: String? = nil) -> ProviderInitializationStatus.ModelMetadata {
        ProviderInitializationStatus.ModelMetadata(id: id, name: name, provider: nil, contextLength: nil)
    }
}
