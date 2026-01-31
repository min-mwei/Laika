import XCTest
@testable import LaikaAgentCore
import LaikaModel
import LaikaShared

final class AgentCoreTests: XCTestCase {
    private struct MockModelRunner: ModelRunner {
        let summary: String
        let toolCalls: [ToolCall]
        let goalPlan: GoalPlan?

        init(summary: String, toolCalls: [ToolCall] = [], goalPlan: GoalPlan? = nil) {
            self.summary = summary
            self.toolCalls = toolCalls
            self.goalPlan = goalPlan
        }

        func generatePlan(context: ContextPack, userGoal: String) async throws -> ModelResponse {
            let assistant = AssistantMessage(render: Document.paragraph(text: summary))
            return ModelResponse(toolCalls: toolCalls, assistant: assistant)
        }

        func parseGoalPlan(context: ContextPack, userGoal: String) async throws -> GoalPlan {
            return goalPlan ?? .unknown
        }

        func generateAnswer(request: LLMCPRequest, logContext: AnswerLogContext) async throws -> ModelResponse {
            let assistant = AssistantMessage(render: Document.paragraph(text: summary))
            return ModelResponse(toolCalls: toolCalls, assistant: assistant)
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

    func testPageSummaryAddsStructuredHeadings() async throws {
        let observation = Observation(
            url: "https://example.com",
            title: "Example",
            text: "Example page text about reliability and testing.",
            elements: []
        )
        let context = ContextPack(origin: "https://example.com", mode: .assist, observation: observation, recentToolCalls: [])
        let goalPlan = GoalPlan(intent: .pageSummary)
        let model = MockModelRunner(summary: "This page explains how testing improves reliability.", goalPlan: goalPlan)
        let orchestrator = AgentOrchestrator(model: model)

        let response = try await orchestrator.runOnce(context: context, userGoal: "Summarize this page")

        XCTAssertTrue(response.summary.contains("Summary:"))
        XCTAssertTrue(response.summary.contains("Key takeaways:"))
        XCTAssertTrue(response.summary.contains("What to verify next:"))
    }

    func testHeuristicPageSummaryAddsHeadings() async throws {
        let observation = Observation(
            url: "https://example.com",
            title: "Example",
            text: "Example page text about observability and performance.",
            elements: []
        )
        let context = ContextPack(origin: "https://example.com", mode: .assist, observation: observation, recentToolCalls: [])
        let model = MockModelRunner(summary: "This page describes observability practices.")
        let orchestrator = AgentOrchestrator(model: model)

        let response = try await orchestrator.runOnce(context: context, userGoal: "Summarize this page")

        XCTAssertTrue(response.summary.contains("Summary:"))
        XCTAssertTrue(response.summary.contains("Key takeaways:"))
        XCTAssertTrue(response.summary.contains("What to verify next:"))
    }

    func testHeuristicCommentSummaryAddsHeadings() async throws {
        let comments = [
            ObservedComment(text: "This is a comment.", author: "user1", age: "1h", score: "10", depth: 0)
        ]
        let observation = Observation(
            url: "https://example.com",
            title: "Example",
            text: "Example page text.",
            elements: [],
            comments: comments
        )
        let context = ContextPack(origin: "https://example.com", mode: .assist, observation: observation, recentToolCalls: [])
        let model = MockModelRunner(summary: "Comments discuss the release.")
        let orchestrator = AgentOrchestrator(model: model)

        let response = try await orchestrator.runOnce(context: context, userGoal: "Summarize the comments")

        XCTAssertTrue(response.summary.contains("Comment themes:"))
        XCTAssertTrue(response.summary.contains("Notable contributors or tools:"))
    }

    func testSummaryIncludesAccessLimitations() async throws {
        let observation = Observation(
            url: "https://example.com",
            title: "Example",
            text: "Limited page content.",
            elements: [],
            signals: [ObservationSignal.paywallOrLogin.rawValue]
        )
        let context = ContextPack(origin: "https://example.com", mode: .assist, observation: observation, recentToolCalls: [])
        let goalPlan = GoalPlan(intent: .pageSummary)
        let model = MockModelRunner(summary: "This page is about Example.", goalPlan: goalPlan)
        let orchestrator = AgentOrchestrator(model: model)

        let response = try await orchestrator.runOnce(context: context, userGoal: "Summarize this page")

        XCTAssertTrue(response.summary.contains("Access limitations:"))
        XCTAssertTrue(response.summary.contains("paywall or login required"))
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

    func testPolicyBlocksCredentialInput() async throws {
        let element = ObservedElement(
            handleId: "el-1",
            role: "input",
            label: "Password",
            boundingBox: BoundingBox(x: 0, y: 0, width: 10, height: 10),
            inputType: "password"
        )
        let observation = Observation(url: "https://example.com", title: "Example", text: "", elements: [element])
        let context = ContextPack(origin: "https://example.com", mode: .assist, observation: observation, recentToolCalls: [])
        let toolCall = ToolCall(
            name: .browserType,
            arguments: ["handleId": .string("el-1"), "text": .string("secret")]
        )
        let model = MockModelRunner(summary: "Typing password.", toolCalls: [toolCall])
        let orchestrator = AgentOrchestrator(model: model)

        let response = try await orchestrator.runOnce(context: context, userGoal: "Fill in the password.")

        XCTAssertEqual(response.actions.first?.policy.decision, .deny)
        XCTAssertEqual(response.actions.first?.policy.reasonCode, "sensitive_field_blocked")
    }

    func testPolicyBlocksPersonalIdInput() async throws {
        let element = ObservedElement(
            handleId: "el-2",
            role: "input",
            label: "Email address",
            boundingBox: BoundingBox(x: 0, y: 0, width: 10, height: 10),
            inputType: "email"
        )
        let observation = Observation(url: "https://example.com", title: "Example", text: "", elements: [element])
        let context = ContextPack(origin: "https://example.com", mode: .assist, observation: observation, recentToolCalls: [])
        let toolCall = ToolCall(
            name: .browserType,
            arguments: ["handleId": .string("el-2"), "text": .string("user@example.com")]
        )
        let model = MockModelRunner(summary: "Typing email.", toolCalls: [toolCall])
        let orchestrator = AgentOrchestrator(model: model)

        let response = try await orchestrator.runOnce(context: context, userGoal: "Fill in the email.")

        XCTAssertEqual(response.actions.first?.policy.decision, .deny)
        XCTAssertEqual(response.actions.first?.policy.reasonCode, "sensitive_field_blocked")
    }

    func testPolicyAllowsNonSensitiveInputWithApproval() async throws {
        let element = ObservedElement(
            handleId: "el-3",
            role: "input",
            label: "Search",
            boundingBox: BoundingBox(x: 0, y: 0, width: 10, height: 10),
            inputType: "text"
        )
        let observation = Observation(url: "https://example.com", title: "Example", text: "", elements: [element])
        let context = ContextPack(origin: "https://example.com", mode: .assist, observation: observation, recentToolCalls: [])
        let toolCall = ToolCall(
            name: .browserType,
            arguments: ["handleId": .string("el-3"), "text": .string("hello")]
        )
        let model = MockModelRunner(summary: "Typing query.", toolCalls: [toolCall])
        let orchestrator = AgentOrchestrator(model: model)

        let response = try await orchestrator.runOnce(context: context, userGoal: "Fill in the search box.")

        XCTAssertEqual(response.actions.first?.policy.decision, .ask)
        XCTAssertEqual(response.actions.first?.policy.reasonCode, "assist_requires_approval")
    }
}
