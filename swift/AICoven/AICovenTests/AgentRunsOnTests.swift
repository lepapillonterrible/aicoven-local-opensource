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

    private func model(_ id: String, name: String? = nil) -> ProviderInitializationStatus.ModelMetadata {
        ProviderInitializationStatus.ModelMetadata(id: id, name: name, provider: nil, contextLength: nil)
    }
}
