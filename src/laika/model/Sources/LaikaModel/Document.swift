import Foundation

public struct Document: Codable, Equatable, Sendable {
    public let type: String
    public let children: [DocumentNode]

    public init(children: [DocumentNode]) {
        self.type = "doc"
        self.children = children
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedType = try container.decode(String.self, forKey: .type)
        guard decodedType == "doc" else {
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Document.type must be 'doc'.")
        }
        type = decodedType
        children = try container.decode([DocumentNode].self, forKey: .children)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode("doc", forKey: .type)
        try container.encode(children, forKey: .children)
    }

    public static func paragraph(text: String) -> Document {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let node = DocumentNode.paragraph(children: [.text(text: trimmed)])
        return Document(children: [node])
    }

    public func plainText() -> String {
        DocumentTextRenderer().render(document: self)
    }

    public func markdown() -> String {
        DocumentMarkdownRenderer().render(document: self)
    }

    private enum CodingKeys: String, CodingKey {
        case type
        case children
    }
}

public enum DocumentNode: Equatable, Sendable {
    case heading(level: Int, children: [DocumentNode])
    case paragraph(children: [DocumentNode])
    case list(ordered: Bool, items: [DocumentNode])
    case listItem(children: [DocumentNode])
    case blockquote(children: [DocumentNode])
    case codeBlock(language: String?, text: String)
    case text(text: String)
    case link(href: String, children: [DocumentNode])
}

extension DocumentNode: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case level
        case children
        case ordered
        case items
        case language
        case text
        case href
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "heading":
            let level = try container.decode(Int.self, forKey: .level)
            let children = try container.decode([DocumentNode].self, forKey: .children)
            self = .heading(level: level, children: children)
        case "paragraph":
            let children = try container.decode([DocumentNode].self, forKey: .children)
            self = .paragraph(children: children)
        case "list":
            let ordered = try container.decode(Bool.self, forKey: .ordered)
            let items = try container.decode([DocumentNode].self, forKey: .items)
            self = .list(ordered: ordered, items: items)
        case "list_item":
            let children = try container.decode([DocumentNode].self, forKey: .children)
            self = .listItem(children: children)
        case "blockquote":
            let children = try container.decode([DocumentNode].self, forKey: .children)
            self = .blockquote(children: children)
        case "code_block":
            let language = try container.decodeIfPresent(String.self, forKey: .language)
            let text = try container.decode(String.self, forKey: .text)
            self = .codeBlock(language: language, text: text)
        case "text":
            let text = try container.decode(String.self, forKey: .text)
            self = .text(text: text)
        case "link":
            let href = try container.decode(String.self, forKey: .href)
            let children = try container.decode([DocumentNode].self, forKey: .children)
            self = .link(href: href, children: children)
        default:
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "Unsupported document node type: \(type)")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .heading(let level, let children):
            try container.encode("heading", forKey: .type)
            try container.encode(level, forKey: .level)
            try container.encode(children, forKey: .children)
        case .paragraph(let children):
            try container.encode("paragraph", forKey: .type)
            try container.encode(children, forKey: .children)
        case .list(let ordered, let items):
            try container.encode("list", forKey: .type)
            try container.encode(ordered, forKey: .ordered)
            try container.encode(items, forKey: .items)
        case .listItem(let children):
            try container.encode("list_item", forKey: .type)
            try container.encode(children, forKey: .children)
        case .blockquote(let children):
            try container.encode("blockquote", forKey: .type)
            try container.encode(children, forKey: .children)
        case .codeBlock(let language, let text):
            try container.encode("code_block", forKey: .type)
            try container.encodeIfPresent(language, forKey: .language)
            try container.encode(text, forKey: .text)
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .link(let href, let children):
            try container.encode("link", forKey: .type)
            try container.encode(href, forKey: .href)
            try container.encode(children, forKey: .children)
        }
    }
}

private struct DocumentTextRenderer {
    func render(document: Document) -> String {
        let parts = document.children.compactMap { renderBlock($0) }
        return parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func renderBlock(_ node: DocumentNode) -> String? {
        switch node {
        case .heading(_, let children):
            return renderInline(children)
        case .paragraph(let children):
            return renderInline(children)
        case .list(let ordered, let items):
            return renderList(items: items, ordered: ordered)
        case .listItem(let children):
            return renderInline(children)
        case .blockquote(let children):
            let inner = renderInline(children)
            return inner.isEmpty ? nil : "> " + inner
        case .codeBlock(_, let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .text, .link:
            let inline = renderInline([node])
            return inline.isEmpty ? nil : inline
        }
    }

    private func renderList(items: [DocumentNode], ordered: Bool) -> String? {
        guard !items.isEmpty else {
            return nil
        }
        var lines: [String] = []
        lines.reserveCapacity(items.count)
        for (index, item) in items.enumerated() {
            let content = renderBlock(item) ?? ""
            let prefix = ordered ? "\(index + 1). " : "- "
            lines.append(prefix + content)
        }
        return lines.joined(separator: "\n")
    }

    private func renderInline(_ nodes: [DocumentNode]) -> String {
        var output = ""
        for node in nodes {
            output.append(renderInlineNode(node))
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func renderInlineNode(_ node: DocumentNode) -> String {
        switch node {
        case .text(let text):
            return text
        case .link(_, let children):
            return renderInline(children)
        case .heading(_, let children):
            return renderInline(children)
        case .paragraph(let children):
            return renderInline(children)
        case .listItem(let children):
            return renderInline(children)
        case .blockquote(let children):
            return renderInline(children)
        case .list:
            return ""
        case .codeBlock(_, let text):
            return text
        }
    }
}

private struct DocumentMarkdownRenderer {
    func render(document: Document) -> String {
        let parts = document.children.compactMap { renderBlock($0) }
        return parts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func renderBlock(_ node: DocumentNode) -> String? {
        switch node {
        case .heading(let level, let children):
            let clamped = max(1, min(level, 6))
            let text = renderInline(children)
            guard !text.isEmpty else {
                return nil
            }
            return String(repeating: "#", count: clamped) + " " + text
        case .paragraph(let children):
            let text = renderInline(children)
            return text.isEmpty ? nil : text
        case .list(let ordered, let items):
            return renderList(items: items, ordered: ordered)
        case .listItem(let children):
            let text = renderListItem(children: children)
            return text.isEmpty ? nil : text
        case .blockquote(let children):
            let inner = renderBlocks(children)
            guard !inner.isEmpty else {
                return nil
            }
            let lines = inner.split(separator: "\n", omittingEmptySubsequences: false)
            return lines.map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n")
        case .codeBlock(let language, let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return nil
            }
            let lang = language?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let fence = lang.isEmpty ? "```" : "```" + lang
            return [fence, trimmed, "```"].joined(separator: "\n")
        case .text, .link:
            let inline = renderInline([node])
            return inline.isEmpty ? nil : inline
        }
    }

    private func renderBlocks(_ nodes: [DocumentNode]) -> String {
        let parts = nodes.compactMap { renderBlock($0) }
        return parts.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func renderList(items: [DocumentNode], ordered: Bool) -> String? {
        guard !items.isEmpty else {
            return nil
        }
        var lines: [String] = []
        lines.reserveCapacity(items.count)
        for (index, item) in items.enumerated() {
            let content: String
            switch item {
            case .listItem(let children):
                content = renderListItem(children: children)
            default:
                content = renderBlock(item) ?? ""
            }
            if content.isEmpty {
                continue
            }
            let parts = content.split(separator: "\n", omittingEmptySubsequences: false)
            let prefix = ordered ? "\(index + 1). " : "- "
            for (lineIndex, line) in parts.enumerated() {
                if lineIndex == 0 {
                    lines.append(prefix + line)
                } else {
                    lines.append("  " + line)
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    private func renderListItem(children: [DocumentNode]) -> String {
        var fragments: [String] = []
        for child in children {
            switch child {
            case .text, .link:
                let inline = renderInline([child])
                if !inline.isEmpty {
                    fragments.append(inline)
                }
            case .paragraph(let inner):
                let text = renderInline(inner)
                if !text.isEmpty {
                    fragments.append(text)
                }
            default:
                if let block = renderBlock(child) {
                    fragments.append(block)
                }
            }
        }
        return fragments.joined(separator: "\n")
    }

    private func renderInline(_ nodes: [DocumentNode]) -> String {
        var output = ""
        for node in nodes {
            output.append(renderInlineNode(node))
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func renderInlineNode(_ node: DocumentNode) -> String {
        switch node {
        case .text(let text):
            return text
        case .link(let href, let children):
            let text = renderInline(children)
            let label = text.isEmpty ? href : text
            return "[" + label + "](" + href + ")"
        case .heading(_, let children):
            return renderInline(children)
        case .paragraph(let children):
            return renderInline(children)
        case .listItem(let children):
            return renderInline(children)
        case .list(let ordered, let items):
            return renderList(items: items, ordered: ordered) ?? ""
        case .blockquote(let children):
            return renderInline(children)
        case .codeBlock(_, let text):
            return text
        }
    }
}
