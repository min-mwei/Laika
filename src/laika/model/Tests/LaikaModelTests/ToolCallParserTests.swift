import XCTest
@testable import LaikaModel
import LaikaShared

final class LLMCPResponseParserTests: XCTestCase {
    func testParsesLLMCPResponse() throws {
        let output = """
        {
          "protocol": { "name": "laika.llmcp", "version": 1 },
          "id": "resp-1",
          "type": "response",
          "created_at": "2026-01-24T12:34:57.123Z",
          "conversation": { "id": "conv-1", "turn": 1 },
          "sender": { "role": "assistant" },
          "in_reply_to": { "request_id": "req-1" },
          "assistant": {
            "title": "Summary",
            "render": {
              "type": "doc",
              "children": [
                { "type": "paragraph", "children": [ { "type": "text", "text": "ok" } ] }
              ]
            }
          },
          "tool_calls": [
            { "name": "browser.click", "arguments": { "handleId": "laika-1" } }
          ]
        }
        """
        let parsed = try LLMCPResponseParser.parse(output)
        XCTAssertEqual(parsed.summary, "ok")
        XCTAssertEqual(parsed.toolCalls.count, 1)
        XCTAssertEqual(parsed.toolCalls.first?.name, .browserClick)
    }

    func testIgnoresUnknownToolNames() throws {
        let output = """
        {
          "protocol": { "name": "laika.llmcp", "version": 1 },
          "id": "resp-2",
          "type": "response",
          "created_at": "2026-01-24T12:34:57.123Z",
          "conversation": { "id": "conv-2", "turn": 1 },
          "sender": { "role": "assistant" },
          "in_reply_to": { "request_id": "req-2" },
          "assistant": {
            "render": { "type": "doc", "children": [] }
          },
          "tool_calls": [
            { "name": "browser.unknown", "arguments": {} }
          ]
        }
        """
        let parsed = try LLMCPResponseParser.parse(output)
        XCTAssertTrue(parsed.toolCalls.isEmpty)
    }

    func testNormalizesObserveDomArguments() throws {
        let output = """
        {
          "protocol": { "name": "laika.llmcp", "version": 1 },
          "id": "resp-3",
          "type": "response",
          "created_at": "2026-01-24T12:34:57.123Z",
          "conversation": { "id": "conv-3", "turn": 1 },
          "sender": { "role": "assistant" },
          "in_reply_to": { "request_id": "req-3" },
          "assistant": {
            "render": {
              "type": "doc",
              "children": [
                { "type": "paragraph", "children": [ { "type": "text", "text": "reading" } ] }
              ]
            }
          },
          "tool_calls": [
            { "name": "browser.observe_dom", "arguments": { "maxItemsChars": 1200 } }
          ]
        }
        """
        let parsed = try LLMCPResponseParser.parse(output)
        XCTAssertEqual(parsed.toolCalls.count, 1)
        let args = parsed.toolCalls.first?.arguments ?? [:]
        XCTAssertNotNil(args["maxItemChars"])
    }

    func testFallbackWhenNoJSON() throws {
        let parsed = try LLMCPResponseParser.parse("hello")
        XCTAssertEqual(parsed.summary, "hello")
    }

    func testLenientParsingHandlesProtocolString() throws {
        let output = """
        {
          "protocol": "laika.llmcp.response.v1",
          "type": "response",
          "sender": "assistant",
          "in_reply_to": "req-9",
          "assistant": {
            "title": "Summary",
            "render": {
              "doc": {
                "type": "doc",
                "children": [
                  { "type": "paragraph", "text": "ok" }
                ]
              }
            }
          },
          "tool_calls": []
        }
        """
        let parsed = try LLMCPResponseParser.parse(output)
        XCTAssertEqual(parsed.summary, "ok")
        XCTAssertTrue(parsed.toolCalls.isEmpty)
    }

    func testLenientParsingIgnoresToolCallsWithoutEnvelope() throws {
        let output = """
        {
          "assistant": {
            "render": {
              "type": "doc",
              "children": [
                { "type": "paragraph", "children": [ { "type": "text", "text": "ok" } ] }
              ]
            }
          },
          "tool_calls": [
            { "name": "browser.click", "arguments": { "handleId": "laika-1" } }
          ]
        }
        """
        let parsed = try LLMCPResponseParser.parse(output)
        XCTAssertEqual(parsed.summary, "ok")
        XCTAssertTrue(parsed.toolCalls.isEmpty)
    }

    func testLenientParsingUnwrapsNestedDocument() throws {
        let output = """
        {
          "protocol": { "name": "laika.llmcp", "version": 1 },
          "id": "resp-4",
          "type": "response",
          "created_at": "2026-01-24T12:34:57.123Z",
          "conversation": { "id": "conv-4", "turn": 1 },
          "sender": { "role": "assistant" },
          "in_reply_to": { "request_id": "req-4" },
          "assistant": {
            "render": {
              "document": {
                "type": "doc",
                "children": [
                  { "type": "doc", "children": [ { "type": "quote", "text": "Nested ok" } ] }
                ]
              }
            }
          },
          "tool_calls": []
        }
        """
        let parsed = try LLMCPResponseParser.parse(output)
        XCTAssertEqual(parsed.summary, "Nested ok")
    }

    func testFallbackAvoidsEchoingRawJSON() throws {
        let output = "{\"protocol\": {\"name\": \"laika.llmcp\", \"version\": 1}, \"type\": \"response\""
        let parsed = try LLMCPResponseParser.parse(output)
        XCTAssertEqual(parsed.summary, "Unable to parse response.")
    }
}
