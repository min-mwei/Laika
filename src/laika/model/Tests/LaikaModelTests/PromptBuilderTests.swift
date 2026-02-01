import XCTest
@testable import LaikaModel

final class PromptBuilderTests: XCTestCase {
    func testMarkdownSystemPromptIsMarkdownOnly() {
        let prompt = PromptBuilder.markdownSystemPrompt()
        XCTAssertTrue(prompt.contains("Output ONLY Markdown"))
        XCTAssertTrue(prompt.contains("Do not output JSON"))
        XCTAssertFalse(prompt.contains("JSON schema"))
    }

    func testCollectionMarkdownPromptRequiresCitationsBlock() {
        let doc = LLMCPDocument(
            docId: "src_1",
            kind: "collection.source.v1",
            trust: "untrusted",
            source: nil,
            content: .object(["markdown": .string("Example body")])
        )
        let request = LLMCPRequest(
            protocolInfo: LLMCPProtocol(name: "laika.llmcp", version: 1),
            id: "req_1",
            type: .request,
            createdAt: "2026-02-01T00:00:00Z",
            conversation: LLMCPConversation(id: "conv_1", turn: 1),
            sender: LLMCPSender(role: "agent"),
            input: LLMCPInput(
                userMessage: LLMCPUserMessage(id: "msg_1", text: "Summarize the sources."),
                task: LLMCPTask(name: "web.answer", args: nil)
            ),
            context: LLMCPContext(documents: [doc]),
            output: LLMCPOutputSpec(format: "markdown"),
            trace: nil
        )
        let prompt = PromptBuilder.markdownUserPrompt(request: request)
        XCTAssertTrue(prompt.contains("---CITATIONS---"))
        XCTAssertTrue(prompt.contains("---END CITATIONS---"))
    }
}
