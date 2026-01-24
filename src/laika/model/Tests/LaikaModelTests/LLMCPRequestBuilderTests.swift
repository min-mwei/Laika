import XCTest
@testable import LaikaModel
import LaikaShared

final class LLMCPRequestBuilderTests: XCTestCase {
    func testAddsCommentCountsAndTopDiscussions() {
        let items = [
            makeItem(title: "Alpha", commentCount: 12),
            makeItem(title: "Beta", commentCount: 200),
            makeItem(title: "Gamma", commentCount: 50)
        ]
        let observation = Observation(
            url: "https://news.ycombinator.com",
            title: "Hacker News",
            text: "",
            elements: [],
            items: items
        )
        let context = ContextPack(
            origin: "https://news.ycombinator.com",
            mode: .assist,
            observation: observation,
            recentToolCalls: []
        )
        let request = LLMCPRequestBuilder.build(context: context, userGoal: "What is this page about?")
        let summaryDoc = request.context.documents.first { $0.kind == "web.observation.summary.v1" }
        guard let summaryDoc,
              case let .object(content) = summaryDoc.content,
              case let .array(itemValues) = content["items"] else {
            XCTFail("Missing summary items in request.")
            return
        }
        let itemObjects = itemValues.compactMap { value -> [String: JSONValue]? in
            if case let .object(object) = value {
                return object
            }
            return nil
        }
        let betaItem = itemObjects.first { object in
            if case let .string(title) = object["title"] {
                return title.contains("Beta")
            }
            return false
        }
        XCTAssertEqual(numberValue(betaItem?["comment_count"]), 200)

        guard case let .array(topDiscussions) = content["top_discussions"],
              let first = topDiscussions.first,
              case let .object(firstObject) = first else {
            XCTFail("Missing top_discussions in request.")
            return
        }
        XCTAssertEqual(numberValue(firstObject["comment_count"]), 200)
    }

    private func makeItem(title: String, commentCount: Int) -> ObservedItem {
        let commentTitle = "\(commentCount) comments"
        let links = [
            ObservedItemLink(title: commentTitle, url: "https://news.ycombinator.com/item?id=\(commentCount)")
        ]
        return ObservedItem(
            title: title,
            url: "https://example.com/\(title.lowercased())",
            snippet: commentTitle,
            tag: "tr",
            linkCount: links.count,
            linkDensity: 0.1,
            handleId: nil,
            links: links
        )
    }

    private func numberValue(_ value: JSONValue?) -> Int? {
        if case let .number(number) = value {
            return Int(number)
        }
        return nil
    }
}
