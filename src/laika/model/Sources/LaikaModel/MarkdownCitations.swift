import Foundation

enum MarkdownCitations {
    static let startMarker = "---CITATIONS---"
    static let endMarker = "---END CITATIONS---"

    static func extract(from markdown: String) -> (markdown: String, citations: [LLMCPCitation]) {
        guard let startRange = markdown.range(of: startMarker) else {
            return (markdown, [])
        }
        guard let endRange = markdown.range(of: endMarker, range: startRange.upperBound..<markdown.endIndex) else {
            return (markdown, [])
        }
        let block = markdown[startRange.upperBound..<endRange.lowerBound]
        var citations: [LLMCPCitation] = []
        for rawLine in block.split(whereSeparator: \.isNewline) {
            let trimmedLine = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedLine.isEmpty {
                continue
            }
            guard let data = trimmedLine.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data, options: []),
                  let dict = json as? [String: Any],
                  let docId = dict["doc_id"] as? String,
                  !docId.isEmpty else {
                continue
            }
            let quote = dict["quote"] as? String
            citations.append(LLMCPCitation(docId: docId, nodeId: nil, handleId: nil, quote: quote))
        }
        var cleaned = markdown
        cleaned.removeSubrange(startRange.lowerBound..<endRange.upperBound)
        cleaned = cleaned.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        return (cleaned, citations)
    }
}
