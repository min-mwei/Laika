import XCTest
@testable import LaikaAgentCore
import LaikaModel
import LaikaShared

final class AgentCoreTests: XCTestCase {
    private struct MockModelRunner: ModelRunner {
        let summary: String

        func generatePlan(context: ContextPack, userGoal: String) async throws -> ModelResponse {
            let assistant = AssistantMessage(render: Document.paragraph(text: summary))
            return ModelResponse(toolCalls: [], assistant: assistant)
        }
    }

    func testAssistSummaryFallsBackWithoutStreamingModel() async throws {
        let element = ObservedElement(
            handleId: "el-1",
            role: "button",
            label: "Continue",
            boundingBox: BoundingBox(x: 0, y: 0, width: 10, height: 10)
        )
        let observation = Observation(url: "https://example.com", title: "Example", text: "", elements: [element])
        let context = ContextPack(origin: "https://example.com", mode: .assist, observation: observation, recentToolCalls: [])

        let model = MockModelRunner(summary: "No tool calls proposed.")
        let orchestrator = AgentOrchestrator(model: model)
        let response = try await orchestrator.runOnce(context: context, userGoal: "What is this page about?")

        XCTAssertTrue(response.summary.isEmpty == false)
        XCTAssertEqual(response.actions.count, 0)
        XCTAssertEqual(response.assistant.render.plainText(), response.summary)
    }

    func testAssistSummaryFallbackIncludesItems() async throws {
        let items = [
            ObservedItem(
                title: "Alpha Beta Gamma",
                url: "https://example.com/a",
                snippet: "Alpha Beta Gamma is a sample item.",
                tag: "article",
                linkCount: 1,
                linkDensity: 0.1
            ),
            ObservedItem(
                title: "Delta Epsilon Zeta",
                url: "https://example.com/b",
                snippet: "Delta Epsilon Zeta follows up with more detail.",
                tag: "article",
                linkCount: 1,
                linkDensity: 0.1
            )
        ]
        let observation = Observation(
            url: "https://example.com",
            title: "Example",
            text: "",
            elements: [],
            items: items
        )
        let context = ContextPack(origin: "https://example.com", mode: .assist, observation: observation, recentToolCalls: [])
        let model = MockModelRunner(summary: "This page is about Example.")
        let orchestrator = AgentOrchestrator(model: model)

        let response = try await orchestrator.runOnce(context: context, userGoal: "What is this page about?")

        XCTAssertTrue(response.summary.contains("Alpha Beta Gamma"))
        XCTAssertEqual(response.actions.count, 0)
        XCTAssertEqual(response.assistant.render.plainText(), response.summary)
    }

    func testTopDiscussionsAppendedForListPages() async throws {
        let items = [
            ObservedItem(
                title: "Alpha",
                url: "https://example.com/a",
                snippet: "12 comments",
                tag: "article",
                linkCount: 1,
                linkDensity: 0.1,
                links: [ObservedItemLink(title: "12 comments", url: "https://example.com/a#comments")]
            ),
            ObservedItem(
                title: "Beta",
                url: "https://example.com/b",
                snippet: "200 comments",
                tag: "article",
                linkCount: 1,
                linkDensity: 0.1,
                links: [ObservedItemLink(title: "200 comments", url: "https://example.com/b#comments")]
            )
        ]
        let observation = Observation(
            url: "https://example.com",
            title: "Example",
            text: "",
            elements: [],
            items: items
        )
        let context = ContextPack(origin: "https://example.com", mode: .assist, observation: observation, recentToolCalls: [])
        let model = MockModelRunner(summary: "This page lists a few items.")
        let orchestrator = AgentOrchestrator(model: model)

        let response = try await orchestrator.runOnce(context: context, userGoal: "summarize this page")

        XCTAssertTrue(response.summary.contains("Top discussions (by comments):"))
        XCTAssertTrue(response.summary.contains("Beta (200 comments)"))
    }

    func testSearchIntentPlansSearchTool() async throws {
        let observation = Observation(url: "https://example.com", title: "Example", text: "", elements: [])
        let context = ContextPack(origin: "https://example.com", mode: .assist, observation: observation, recentToolCalls: [])
        let model = MockModelRunner(summary: "No tool calls proposed.")
        let orchestrator = AgentOrchestrator(model: model)

        let response = try await orchestrator.runOnce(context: context, userGoal: "Search the web for OpenAI GPT-5")

        XCTAssertEqual(response.actions.count, 1)
        XCTAssertEqual(response.actions.first?.toolCall.name, .search)
    }

    func testSearchIntentStripsSummarySuffix() async throws {
        let observation = Observation(url: "https://example.com", title: "Example", text: "", elements: [])
        let context = ContextPack(origin: "https://example.com", mode: .assist, observation: observation, recentToolCalls: [])
        let model = MockModelRunner(summary: "No tool calls proposed.")
        let orchestrator = AgentOrchestrator(model: model)

        let response = try await orchestrator.runOnce(
            context: context,
            userGoal: "Search the web for OpenAI GPT-5 and summarize the top results"
        )

        XCTAssertEqual(response.actions.count, 1)
        XCTAssertEqual(response.actions.first?.toolCall.name, .search)
        if case let .string(query)? = response.actions.first?.toolCall.arguments["query"] {
            XCTAssertEqual(query, "OpenAI GPT-5")
        } else {
            XCTFail("Missing search query")
        }
    }
}
