import CryptoKit
import Foundation
import SQLite3

public enum CollectionStoreError: Error, CustomStringConvertible {
    case databaseUnavailable(String)
    case invalidRequest(String)
    case sqliteFailure(String)

    public var description: String {
        switch self {
        case let .databaseUnavailable(message),
             let .invalidRequest(message),
             let .sqliteFailure(message):
            return message
        }
    }
}

public enum SourceKind: String, Codable, Sendable {
    case url
    case note
    case image
}

public enum CaptureStatus: String, Codable, Sendable {
    case pending
    case captured
    case failed
}

public struct CollectionRecord: Codable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let tags: [String]
    public let createdAtMs: Int64
    public let updatedAtMs: Int64
}

public struct SourceRecord: Codable, Equatable, Sendable {
    public let id: String
    public let collectionId: String
    public let kind: SourceKind
    public let url: String?
    public let title: String?
    public let captureStatus: CaptureStatus
    public let addedAtMs: Int64
    public let capturedAtMs: Int64?
    public let updatedAtMs: Int64
}

public struct SourceSnapshot: Codable, Equatable, Sendable {
    public let id: String
    public let collectionId: String
    public let url: String
    public let title: String?
    public let capturedAtMs: Int64?
    public let captureSummary: String?
    public let captureMarkdown: String
    public let extractedLinks: [CapturedLink]
}

public struct CapturedLink: Codable, Equatable, Sendable {
    public let url: String
    public let text: String?
    public let context: String?
}

public struct ChatEventRecord: Codable, Equatable, Sendable {
    public let id: String
    public let collectionId: String
    public let role: String
    public let markdown: String
    public let citationsJSON: String
    public let createdAtMs: Int64
}

public struct SourceInput: Codable, Equatable, Sendable {
    public enum SourceType: String, Codable, Sendable {
        case url
        case note
    }

    public let type: SourceType
    public let url: String?
    public let title: String?
    public let text: String?

    public init(type: SourceType, url: String? = nil, title: String? = nil, text: String? = nil) {
        self.type = type
        self.url = url
        self.title = title
        self.text = text
    }
}

public struct AddSourcesResult: Codable, Equatable, Sendable {
    public let sources: [SourceRecord]
    public let ignoredCount: Int
    public let dedupedCount: Int
}

public actor CollectionStore {
    private let databaseURL: URL?
    private var database: SQLiteDatabase?
    private var openError: String?

    public init(databaseURL: URL? = LaikaPaths.databaseURL()) {
        self.databaseURL = databaseURL
    }

    public func listCollections() throws -> (collections: [CollectionRecord], activeCollectionId: String?) {
        let db = try openDatabase()
        let activeId = try fetchActiveCollectionId(db: db)
        let collections = try fetchCollections(db: db)
        return (collections, activeId)
    }

    public func createCollection(title: String, tags: [String] = []) throws -> CollectionRecord {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw CollectionStoreError.invalidRequest("collection title required")
        }
        let db = try openDatabase()
        let nowMs = currentTimeMs()
        let collectionId = makeId(prefix: "col")
        let tagsJSON = encodeJSONArray(tags)
        let insertSQL = """
        INSERT INTO collections (id, title, tags_json, created_at_ms, updated_at_ms)
        VALUES (?, ?, ?, ?, ?);
        """
        let statement = try db.prepare(insertSQL)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, collectionId, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, trimmedTitle, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 3, tagsJSON, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(statement, 4, nowMs)
        sqlite3_bind_int64(statement, 5, nowMs)
        try db.step(statement)
        try setActiveCollectionId(collectionId, db: db)
        return CollectionRecord(id: collectionId, title: trimmedTitle, tags: tags, createdAtMs: nowMs, updatedAtMs: nowMs)
    }

    public func setActiveCollection(_ collectionId: String?) throws {
        let db = try openDatabase()
        if let collectionId {
            try setActiveCollectionId(collectionId, db: db)
        } else {
            try clearActiveCollectionId(db: db)
        }
    }

    public func listSources(collectionId: String) throws -> [SourceRecord] {
        let db = try openDatabase()
        return try fetchSources(collectionId: collectionId, db: db)
    }

    public func getCollection(collectionId: String) throws -> CollectionRecord? {
        let trimmedId = collectionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedId.isEmpty else {
            throw CollectionStoreError.invalidRequest("collection id required")
        }
        let db = try openDatabase()
        let querySQL = """
        SELECT id, title, tags_json, created_at_ms, updated_at_ms
        FROM collections
        WHERE id = ?
        LIMIT 1;
        """
        let statement = try db.prepare(querySQL)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, trimmedId, -1, SQLITE_TRANSIENT)
        if sqlite3_step(statement) == SQLITE_ROW {
            let id = db.columnText(statement, index: 0)
            let title = db.columnText(statement, index: 1)
            let tagsJSON = db.columnText(statement, index: 2)
            let createdAt = sqlite3_column_int64(statement, 3)
            let updatedAt = sqlite3_column_int64(statement, 4)
            let tags = decodeJSONArray(tagsJSON)
            return CollectionRecord(
                id: id,
                title: title,
                tags: tags,
                createdAtMs: createdAt,
                updatedAtMs: updatedAt
            )
        }
        return nil
    }

    public func listSourceSnapshots(collectionId: String, limit: Int = 10) throws -> [SourceSnapshot] {
        let trimmedId = collectionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedId.isEmpty else {
            throw CollectionStoreError.invalidRequest("collection id required")
        }
        let cappedLimit = max(1, min(limit, 50))
        let db = try openDatabase()
        let querySQL = """
        SELECT id, url, title, captured_at_ms, capture_summary, capture_markdown, extracted_links_json
        FROM sources
        WHERE collection_id = ?
          AND capture_status = 'captured'
          AND capture_markdown IS NOT NULL
        ORDER BY captured_at_ms DESC, added_at_ms DESC
        LIMIT ?;
        """
        let statement = try db.prepare(querySQL)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, trimmedId, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(statement, 2, Int64(cappedLimit))
        var snapshots: [SourceSnapshot] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = db.columnText(statement, index: 0)
            let url = db.columnText(statement, index: 1)
            let title = db.columnOptionalText(statement, index: 2)
            let capturedAt = sqlite3_column_type(statement, 3) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 3)
            let summary = db.columnOptionalText(statement, index: 4)
            let markdown = db.columnText(statement, index: 5)
            let linksJSON = db.columnText(statement, index: 6)
            let links = decodeLinks(linksJSON)
            snapshots.append(SourceSnapshot(
                id: id,
                collectionId: trimmedId,
                url: url,
                title: title,
                capturedAtMs: capturedAt,
                captureSummary: summary,
                captureMarkdown: markdown,
                extractedLinks: links
            ))
        }
        return snapshots
    }

    public func addChatEvent(
        collectionId: String,
        role: String,
        markdown: String,
        citationsJSON: String = "[]"
    ) throws -> ChatEventRecord {
        let trimmedCollectionId = collectionId.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedMarkdown = markdown.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCollectionId.isEmpty else {
            throw CollectionStoreError.invalidRequest("collection id required")
        }
        guard !trimmedMarkdown.isEmpty else {
            throw CollectionStoreError.invalidRequest("chat markdown required")
        }
        let normalizedRole: String
        switch role {
        case "user", "assistant", "system":
            normalizedRole = role
        default:
            normalizedRole = "assistant"
        }
        let db = try openDatabase()
        let nowMs = currentTimeMs()
        let eventId = makeId(prefix: "chat")
        let insertSQL = """
        INSERT INTO chat_events (id, collection_id, role, markdown, citations_json, created_at_ms)
        VALUES (?, ?, ?, ?, ?, ?);
        """
        let statement = try db.prepare(insertSQL)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, eventId, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, trimmedCollectionId, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 3, normalizedRole, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 4, trimmedMarkdown, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 5, citationsJSON, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(statement, 6, nowMs)
        try db.step(statement)
        try touchCollection(collectionId: trimmedCollectionId, nowMs: nowMs, db: db)
        return ChatEventRecord(
            id: eventId,
            collectionId: trimmedCollectionId,
            role: normalizedRole,
            markdown: trimmedMarkdown,
            citationsJSON: citationsJSON,
            createdAtMs: nowMs
        )
    }

    public func listChatEvents(collectionId: String, limit: Int = 60) throws -> [ChatEventRecord] {
        let trimmedId = collectionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedId.isEmpty else {
            throw CollectionStoreError.invalidRequest("collection id required")
        }
        let cappedLimit = max(1, min(limit, 200))
        let db = try openDatabase()
        let querySQL = """
        SELECT id, role, markdown, citations_json, created_at_ms
        FROM chat_events
        WHERE collection_id = ?
        ORDER BY created_at_ms ASC
        LIMIT ?;
        """
        let statement = try db.prepare(querySQL)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, trimmedId, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(statement, 2, Int64(cappedLimit))
        var events: [ChatEventRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = db.columnText(statement, index: 0)
            let role = db.columnText(statement, index: 1)
            let markdown = db.columnText(statement, index: 2)
            let citationsJSON = db.columnText(statement, index: 3)
            let createdAt = sqlite3_column_int64(statement, 4)
            events.append(ChatEventRecord(
                id: id,
                collectionId: trimmedId,
                role: role,
                markdown: markdown,
                citationsJSON: citationsJSON,
                createdAtMs: createdAt
            ))
        }
        return events
    }

    public func clearChatEvents(collectionId: String) throws {
        let trimmedId = collectionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedId.isEmpty else {
            throw CollectionStoreError.invalidRequest("collection id required")
        }
        let db = try openDatabase()
        let statement = try db.prepare("DELETE FROM chat_events WHERE collection_id = ?;")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, trimmedId, -1, SQLITE_TRANSIENT)
        try db.step(statement)
        try touchCollection(collectionId: trimmedId, nowMs: currentTimeMs(), db: db)
    }

    public func deleteCollection(collectionId: String) throws -> String? {
        let trimmedId = collectionId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedId.isEmpty else {
            throw CollectionStoreError.invalidRequest("collection id required")
        }
        let db = try openDatabase()
        let statement = try db.prepare("DELETE FROM collections WHERE id = ?;")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, trimmedId, -1, SQLITE_TRANSIENT)
        try db.step(statement)
        if db.changes() == 0 {
            throw CollectionStoreError.invalidRequest("collection_not_found")
        }
        let activeId = try fetchActiveCollectionId(db: db)
        if activeId == trimmedId {
            if let nextActive = try fetchMostRecentCollectionId(db: db) {
                try setActiveCollectionId(nextActive, db: db)
                return nextActive
            }
            try clearActiveCollectionId(db: db)
            return nil
        }
        return activeId
    }

    public func deleteSource(collectionId: String, sourceId: String) throws {
        let trimmedCollectionId = collectionId.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedSourceId = sourceId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCollectionId.isEmpty, !trimmedSourceId.isEmpty else {
            throw CollectionStoreError.invalidRequest("collection id and source id required")
        }
        let db = try openDatabase()
        let statement = try db.prepare("DELETE FROM sources WHERE id = ? AND collection_id = ?;")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, trimmedSourceId, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, trimmedCollectionId, -1, SQLITE_TRANSIENT)
        try db.step(statement)
        if db.changes() == 0 {
            throw CollectionStoreError.invalidRequest("source_not_found")
        }
        try touchCollection(collectionId: trimmedCollectionId, nowMs: currentTimeMs(), db: db)
    }

    public func addSources(collectionId: String, sources: [SourceInput]) throws -> AddSourcesResult {
        let db = try openDatabase()
        if sources.isEmpty {
            return AddSourcesResult(sources: [], ignoredCount: 0, dedupedCount: 0)
        }
        let nowMs = currentTimeMs()
        var inserted: [SourceRecord] = []
        var ignoredCount = 0
        var dedupedCount = 0
        for sourceInput in sources {
            switch sourceInput.type {
            case .url:
                guard let url = sourceInput.url?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !url.isEmpty else {
                    ignoredCount += 1
                    continue
                }
                let normalized = normalizeURL(url)
                guard isHTTPURL(normalized) else {
                    ignoredCount += 1
                    continue
                }
                let sourceId = makeId(prefix: "src")
                let insertSQL = """
                INSERT INTO sources (
                  id, collection_id, kind, url, normalized_url, title,
                  provenance_json, capture_status, capture_version,
                  added_at_ms, updated_at_ms
                ) VALUES (?, ?, 'url', ?, ?, ?, '{}', 'pending', 1, ?, ?);
                """
                let insertStatement = try db.prepare(insertSQL)
                sqlite3_bind_text(insertStatement, 1, sourceId, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(insertStatement, 2, collectionId, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(insertStatement, 3, url, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(insertStatement, 4, normalized, -1, SQLITE_TRANSIENT)
                if let title = sourceInput.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
                    sqlite3_bind_text(insertStatement, 5, title, -1, SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(insertStatement, 5)
                }
                sqlite3_bind_int64(insertStatement, 6, nowMs)
                sqlite3_bind_int64(insertStatement, 7, nowMs)
                let insertResult = sqlite3_step(insertStatement)
                sqlite3_finalize(insertStatement)
                if insertResult == SQLITE_CONSTRAINT {
                    dedupedCount += 1
                    continue
                }
                if insertResult != SQLITE_DONE {
                    throw CollectionStoreError.sqliteFailure(db.lastErrorMessage())
                }
                try queueCaptureJob(
                    sourceId: sourceId,
                    collectionId: collectionId,
                    url: url,
                    nowMs: nowMs,
                    db: db
                )
                inserted.append(SourceRecord(
                    id: sourceId,
                    collectionId: collectionId,
                    kind: .url,
                    url: url,
                    title: sourceInput.title,
                    captureStatus: .pending,
                    addedAtMs: nowMs,
                    capturedAtMs: nil,
                    updatedAtMs: nowMs
                ))
            case .note:
                guard let text = sourceInput.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty else {
                    ignoredCount += 1
                    continue
                }
                let sourceId = makeId(prefix: "src")
                let insertSQL = """
                INSERT INTO sources (
                  id, collection_id, kind, title,
                  provenance_json, capture_status, capture_version,
                  capture_markdown, added_at_ms, captured_at_ms, updated_at_ms
                ) VALUES (?, ?, 'note', ?, '{}', 'captured', 1, ?, ?, ?, ?);
                """
                let insertStatement = try db.prepare(insertSQL)
                sqlite3_bind_text(insertStatement, 1, sourceId, -1, SQLITE_TRANSIENT)
                sqlite3_bind_text(insertStatement, 2, collectionId, -1, SQLITE_TRANSIENT)
                if let title = sourceInput.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
                    sqlite3_bind_text(insertStatement, 3, title, -1, SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(insertStatement, 3)
                }
                sqlite3_bind_text(insertStatement, 4, text, -1, SQLITE_TRANSIENT)
                sqlite3_bind_int64(insertStatement, 5, nowMs)
                sqlite3_bind_int64(insertStatement, 6, nowMs)
                sqlite3_bind_int64(insertStatement, 7, nowMs)
                try db.step(insertStatement)
                inserted.append(SourceRecord(
                    id: sourceId,
                    collectionId: collectionId,
                    kind: .note,
                    url: nil,
                    title: sourceInput.title,
                    captureStatus: .captured,
                    addedAtMs: nowMs,
                    capturedAtMs: nowMs,
                    updatedAtMs: nowMs
                ))
            }
        }
        if !inserted.isEmpty {
            try touchCollection(collectionId: collectionId, nowMs: nowMs, db: db)
        }
        return AddSourcesResult(sources: inserted, ignoredCount: ignoredCount, dedupedCount: dedupedCount)
    }

    public func markSourceCaptured(
        collectionId: String,
        url: String,
        title: String?,
        markdown: String,
        links: [CapturedLink]
    ) throws {
        let trimmedCollectionId = collectionId.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUrl = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCollectionId.isEmpty, !trimmedUrl.isEmpty else {
            throw CollectionStoreError.invalidRequest("collection id and url required")
        }
        let db = try openDatabase()
        let normalized = normalizeURL(trimmedUrl)
        guard isHTTPURL(normalized) else {
            throw CollectionStoreError.invalidRequest("invalid_url")
        }
        guard let sourceId = try fetchSourceId(collectionId: trimmedCollectionId, normalizedUrl: normalized, db: db) else {
            throw CollectionStoreError.invalidRequest("source_not_found")
        }
        let nowMs = currentTimeMs()
        let summary = summarizeMarkdown(markdown, maxChars: 280)
        let contentHash = hashMarkdown(markdown)
        let linksJSON = encodeLinks(links)
        let updateSQL = """
        UPDATE sources
        SET title = COALESCE(?, title),
            capture_status = 'captured',
            capture_markdown = ?,
            capture_error = NULL,
            capture_summary = ?,
            content_hash = ?,
            extracted_links_json = ?,
            captured_at_ms = ?,
            updated_at_ms = ?
        WHERE id = ? AND collection_id = ?;
        """
        let statement = try db.prepare(updateSQL)
        defer { sqlite3_finalize(statement) }
        if let title = title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            sqlite3_bind_text(statement, 1, title, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(statement, 1)
        }
        sqlite3_bind_text(statement, 2, markdown, -1, SQLITE_TRANSIENT)
        if let summary {
            sqlite3_bind_text(statement, 3, summary, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(statement, 3)
        }
        if let contentHash {
            sqlite3_bind_text(statement, 4, contentHash, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(statement, 4)
        }
        sqlite3_bind_text(statement, 5, linksJSON, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(statement, 6, nowMs)
        sqlite3_bind_int64(statement, 7, nowMs)
        sqlite3_bind_text(statement, 8, sourceId, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 9, trimmedCollectionId, -1, SQLITE_TRANSIENT)
        try db.step(statement)
        try updateCaptureJobs(sourceId: sourceId, status: "succeeded", error: nil, nowMs: nowMs, db: db)
        try touchCollection(collectionId: trimmedCollectionId, nowMs: nowMs, db: db)
    }

    public func markSourceCaptureFailed(
        collectionId: String,
        url: String,
        error: String
    ) throws {
        let trimmedCollectionId = collectionId.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUrl = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedError = error.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCollectionId.isEmpty, !trimmedUrl.isEmpty else {
            throw CollectionStoreError.invalidRequest("collection id and url required")
        }
        let db = try openDatabase()
        let normalized = normalizeURL(trimmedUrl)
        guard isHTTPURL(normalized) else {
            throw CollectionStoreError.invalidRequest("invalid_url")
        }
        guard let sourceId = try fetchSourceId(collectionId: trimmedCollectionId, normalizedUrl: normalized, db: db) else {
            throw CollectionStoreError.invalidRequest("source_not_found")
        }
        let nowMs = currentTimeMs()
        let updateSQL = """
        UPDATE sources
        SET capture_status = 'failed',
            capture_error = ?,
            updated_at_ms = ?
        WHERE id = ? AND collection_id = ?;
        """
        let statement = try db.prepare(updateSQL)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, trimmedError.isEmpty ? "capture_failed" : trimmedError, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(statement, 2, nowMs)
        sqlite3_bind_text(statement, 3, sourceId, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 4, trimmedCollectionId, -1, SQLITE_TRANSIENT)
        try db.step(statement)
        try updateCaptureJobs(sourceId: sourceId, status: "failed", error: trimmedError, nowMs: nowMs, db: db)
        try touchCollection(collectionId: trimmedCollectionId, nowMs: nowMs, db: db)
    }

    private func openDatabase() throws -> SQLiteDatabase {
        if let database {
            return database
        }
        if let openError {
            throw CollectionStoreError.databaseUnavailable(openError)
        }
        guard let databaseURL else {
            let message = "database_path_unavailable"
            openError = message
            throw CollectionStoreError.databaseUnavailable(message)
        }
        do {
            let db = try SQLiteDatabase(url: databaseURL)
            try db.exec(sql: schemaSQL)
            database = db
            return db
        } catch {
            let message = (error as? CollectionStoreError)?.description ?? error.localizedDescription
            openError = message
            throw CollectionStoreError.databaseUnavailable(message)
        }
    }

    private func fetchCollections(db: SQLiteDatabase) throws -> [CollectionRecord] {
        let querySQL = """
        SELECT id, title, tags_json, created_at_ms, updated_at_ms
        FROM collections
        ORDER BY updated_at_ms DESC;
        """
        let statement = try db.prepare(querySQL)
        defer { sqlite3_finalize(statement) }
        var collections: [CollectionRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = db.columnText(statement, index: 0)
            let title = db.columnText(statement, index: 1)
            let tagsJSON = db.columnText(statement, index: 2)
            let createdAt = sqlite3_column_int64(statement, 3)
            let updatedAt = sqlite3_column_int64(statement, 4)
            let tags = decodeJSONArray(tagsJSON)
            collections.append(CollectionRecord(
                id: id,
                title: title,
                tags: tags,
                createdAtMs: createdAt,
                updatedAtMs: updatedAt
            ))
        }
        return collections
    }

    private func fetchMostRecentCollectionId(db: SQLiteDatabase) throws -> String? {
        let querySQL = "SELECT id FROM collections ORDER BY updated_at_ms DESC LIMIT 1;"
        let statement = try db.prepare(querySQL)
        defer { sqlite3_finalize(statement) }
        if sqlite3_step(statement) == SQLITE_ROW {
            let value = db.columnText(statement, index: 0)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private func fetchSources(collectionId: String, db: SQLiteDatabase) throws -> [SourceRecord] {
        let querySQL = """
        SELECT id, kind, url, title, capture_status, added_at_ms, captured_at_ms, updated_at_ms
        FROM sources
        WHERE collection_id = ?
        ORDER BY added_at_ms DESC;
        """
        let statement = try db.prepare(querySQL)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, collectionId, -1, SQLITE_TRANSIENT)
        var sources: [SourceRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let id = db.columnText(statement, index: 0)
            let kindRaw = db.columnText(statement, index: 1)
            let url = db.columnOptionalText(statement, index: 2)
            let title = db.columnOptionalText(statement, index: 3)
            let statusRaw = db.columnText(statement, index: 4)
            let addedAt = sqlite3_column_int64(statement, 5)
            let capturedAt = sqlite3_column_type(statement, 6) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 6)
            let updatedAt = sqlite3_column_int64(statement, 7)
            let kind = SourceKind(rawValue: kindRaw) ?? .url
            let status = CaptureStatus(rawValue: statusRaw) ?? .pending
            sources.append(SourceRecord(
                id: id,
                collectionId: collectionId,
                kind: kind,
                url: url,
                title: title,
                captureStatus: status,
                addedAtMs: addedAt,
                capturedAtMs: capturedAt,
                updatedAtMs: updatedAt
            ))
        }
        return sources
    }

    private func touchCollection(collectionId: String, nowMs: Int64, db: SQLiteDatabase) throws {
        let updateSQL = "UPDATE collections SET updated_at_ms = ? WHERE id = ?;"
        let statement = try db.prepare(updateSQL)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, nowMs)
        sqlite3_bind_text(statement, 2, collectionId, -1, SQLITE_TRANSIENT)
        try db.step(statement)
    }

    private func queueCaptureJob(
        sourceId: String,
        collectionId: String,
        url: String,
        nowMs: Int64,
        db: SQLiteDatabase
    ) throws {
        let jobId = makeId(prefix: "job")
        let insertSQL = """
        INSERT INTO capture_jobs (
          id, collection_id, source_id, url, dedupe_key,
          status, attempt_count, max_attempts,
          created_at_ms, updated_at_ms
        ) VALUES (?, ?, ?, ?, '', 'queued', 0, 3, ?, ?);
        """
        let statement = try db.prepare(insertSQL)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, jobId, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, collectionId, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 3, sourceId, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 4, url, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(statement, 5, nowMs)
        sqlite3_bind_int64(statement, 6, nowMs)
        try db.step(statement)
    }

    private func fetchSourceId(collectionId: String, normalizedUrl: String, db: SQLiteDatabase) throws -> String? {
        let querySQL = """
        SELECT id
        FROM sources
        WHERE collection_id = ? AND normalized_url = ?
        LIMIT 1;
        """
        let statement = try db.prepare(querySQL)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, collectionId, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, normalizedUrl, -1, SQLITE_TRANSIENT)
        if sqlite3_step(statement) == SQLITE_ROW {
            let id = db.columnText(statement, index: 0)
            return id.isEmpty ? nil : id
        }
        return nil
    }

    private func updateCaptureJobs(
        sourceId: String,
        status: String,
        error: String?,
        nowMs: Int64,
        db: SQLiteDatabase
    ) throws {
        let updateSQL = """
        UPDATE capture_jobs
        SET status = ?,
            last_error = ?,
            attempt_count = CASE WHEN attempt_count < 1 THEN 1 ELSE attempt_count END,
            updated_at_ms = ?,
            finished_at_ms = ?,
            started_at_ms = COALESCE(started_at_ms, ?)
        WHERE source_id = ? AND status IN ('queued', 'running');
        """
        let statement = try db.prepare(updateSQL)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, status, -1, SQLITE_TRANSIENT)
        if let error, !error.isEmpty {
            sqlite3_bind_text(statement, 2, error, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(statement, 2)
        }
        sqlite3_bind_int64(statement, 3, nowMs)
        sqlite3_bind_int64(statement, 4, nowMs)
        sqlite3_bind_int64(statement, 5, nowMs)
        sqlite3_bind_text(statement, 6, sourceId, -1, SQLITE_TRANSIENT)
        try db.step(statement)
    }

    private func fetchActiveCollectionId(db: SQLiteDatabase) throws -> String? {
        let querySQL = "SELECT value FROM meta WHERE key = 'active_collection_id';"
        let statement = try db.prepare(querySQL)
        defer { sqlite3_finalize(statement) }
        if sqlite3_step(statement) == SQLITE_ROW {
            let value = db.columnText(statement, index: 0)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private func setActiveCollectionId(_ collectionId: String, db: SQLiteDatabase) throws {
        let statement = try db.prepare("INSERT OR REPLACE INTO meta (key, value) VALUES ('active_collection_id', ?);")
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, collectionId, -1, SQLITE_TRANSIENT)
        try db.step(statement)
    }

    private func clearActiveCollectionId(db: SQLiteDatabase) throws {
        let statement = try db.prepare("DELETE FROM meta WHERE key = 'active_collection_id';")
        defer { sqlite3_finalize(statement) }
        try db.step(statement)
    }

    private func currentTimeMs() -> Int64 {
        return Int64(Date().timeIntervalSince1970 * 1000.0)
    }

    private func makeId(prefix: String) -> String {
        let uuid = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return "\(prefix)_\(uuid)"
    }

    private func normalizeURL(_ raw: String) -> String {
        guard let url = URL(string: raw) else {
            return raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return raw.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        }
        components.fragment = nil
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        let normalized = components.url?.absoluteString ?? raw
        return normalized.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private func isHTTPURL(_ raw: String) -> Bool {
        guard let url = URL(string: raw) else {
            return false
        }
        guard let scheme = url.scheme?.lowercased() else {
            return false
        }
        return scheme == "http" || scheme == "https"
    }

    private func encodeJSONArray(_ array: [String]) -> String {
        guard let data = try? JSONEncoder().encode(array),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }

    private func encodeLinks(_ links: [CapturedLink]) -> String {
        guard let data = try? JSONEncoder().encode(links),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }

    private func decodeLinks(_ json: String) -> [CapturedLink] {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([CapturedLink].self, from: data) else {
            return []
        }
        return decoded
    }

    private func decodeJSONArray(_ json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String].self, from: data) else {
            return []
        }
        return decoded
    }

    private func summarizeMarkdown(_ markdown: String, maxChars: Int) -> String? {
        let trimmed = markdown.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        if trimmed.count <= maxChars {
            return trimmed
        }
        return String(trimmed.prefix(maxChars))
    }

    private func hashMarkdown(_ markdown: String) -> String? {
        guard let data = markdown.data(using: .utf8) else {
            return nil
        }
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

private let schemaSQL = """
BEGIN;
PRAGMA user_version = 1;

CREATE TABLE IF NOT EXISTS meta (
  key TEXT PRIMARY KEY NOT NULL,
  value TEXT NOT NULL
);

INSERT OR IGNORE INTO meta(key, value) VALUES ('schema_version', '1');

CREATE TABLE IF NOT EXISTS collections (
  id TEXT PRIMARY KEY NOT NULL CHECK(id LIKE 'col_%'),
  title TEXT NOT NULL,
  tags_json TEXT NOT NULL DEFAULT '[]',
  created_at_ms INTEGER NOT NULL,
  updated_at_ms INTEGER NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_collections_updated_at
  ON collections(updated_at_ms DESC);

CREATE TABLE IF NOT EXISTS sources (
  id TEXT PRIMARY KEY NOT NULL CHECK(id LIKE 'src_%'),
  collection_id TEXT NOT NULL,
  kind TEXT NOT NULL CHECK(kind IN ('url', 'note', 'image')),

  url TEXT,
  normalized_url TEXT,
  title TEXT,

  provenance_json TEXT NOT NULL DEFAULT '{}',

  capture_status TEXT NOT NULL DEFAULT 'pending'
    CHECK(capture_status IN ('pending', 'captured', 'failed')),
  capture_version INTEGER NOT NULL DEFAULT 1 CHECK(capture_version >= 1),
  content_hash TEXT,
  capture_error TEXT,
  capture_summary TEXT,
  capture_markdown TEXT,

  extracted_links_json TEXT NOT NULL DEFAULT '[]',
  media_json TEXT NOT NULL DEFAULT '{}',

  added_at_ms INTEGER NOT NULL,
  captured_at_ms INTEGER,
  updated_at_ms INTEGER NOT NULL,

  FOREIGN KEY(collection_id) REFERENCES collections(id) ON DELETE CASCADE,

  CHECK(kind <> 'url' OR (url IS NOT NULL AND normalized_url IS NOT NULL)),
  CHECK(kind <> 'note' OR (capture_markdown IS NOT NULL))
);

CREATE INDEX IF NOT EXISTS idx_sources_collection_added
  ON sources(collection_id, added_at_ms DESC);

CREATE INDEX IF NOT EXISTS idx_sources_collection_status_added
  ON sources(collection_id, capture_status, added_at_ms DESC);

CREATE INDEX IF NOT EXISTS idx_sources_collection_captured
  ON sources(collection_id, captured_at_ms DESC);

CREATE UNIQUE INDEX IF NOT EXISTS idx_sources_unique_normalized_url_per_collection
  ON sources(collection_id, normalized_url)
  WHERE kind = 'url' AND normalized_url IS NOT NULL;

CREATE TABLE IF NOT EXISTS capture_jobs (
  id TEXT PRIMARY KEY NOT NULL CHECK(id LIKE 'job_%'),
  collection_id TEXT NOT NULL,
  source_id TEXT NOT NULL,
  url TEXT NOT NULL,
  dedupe_key TEXT NOT NULL DEFAULT '',

  status TEXT NOT NULL DEFAULT 'queued'
    CHECK(status IN ('queued', 'running', 'succeeded', 'failed', 'cancelled')),
  attempt_count INTEGER NOT NULL DEFAULT 0 CHECK(attempt_count >= 0),
  max_attempts INTEGER NOT NULL DEFAULT 3 CHECK(max_attempts >= 1),
  last_error TEXT,

  created_at_ms INTEGER NOT NULL,
  updated_at_ms INTEGER NOT NULL,
  started_at_ms INTEGER,
  finished_at_ms INTEGER,

  FOREIGN KEY(collection_id) REFERENCES collections(id) ON DELETE CASCADE,
  FOREIGN KEY(source_id) REFERENCES sources(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_capture_jobs_status_updated
  ON capture_jobs(status, updated_at_ms DESC);

CREATE INDEX IF NOT EXISTS idx_capture_jobs_collection_status
  ON capture_jobs(collection_id, status, created_at_ms DESC);

CREATE INDEX IF NOT EXISTS idx_capture_jobs_source_status
  ON capture_jobs(source_id, status, updated_at_ms DESC);

CREATE UNIQUE INDEX IF NOT EXISTS idx_capture_jobs_one_active_per_source
  ON capture_jobs(source_id)
  WHERE status IN ('queued', 'running');

CREATE UNIQUE INDEX IF NOT EXISTS idx_capture_jobs_one_active_per_dedupe_key
  ON capture_jobs(dedupe_key)
  WHERE status IN ('queued', 'running') AND dedupe_key <> '';

CREATE TABLE IF NOT EXISTS chat_events (
  id TEXT PRIMARY KEY NOT NULL CHECK(id LIKE 'chat_%'),
  collection_id TEXT NOT NULL,

  role TEXT NOT NULL CHECK(role IN ('user', 'assistant', 'system')),
  markdown TEXT NOT NULL,
  citations_json TEXT NOT NULL DEFAULT '[]',
  tool_calls_json TEXT NOT NULL DEFAULT '[]',
  tool_results_json TEXT NOT NULL DEFAULT '[]',

  model_json TEXT NOT NULL DEFAULT '{}',

  created_at_ms INTEGER NOT NULL,

  FOREIGN KEY(collection_id) REFERENCES collections(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_chat_events_collection_created
  ON chat_events(collection_id, created_at_ms ASC);

CREATE TABLE IF NOT EXISTS artifacts (
  id TEXT PRIMARY KEY NOT NULL CHECK(id LIKE 'art_%'),
  collection_id TEXT NOT NULL,

  type TEXT NOT NULL,
  title TEXT NOT NULL,
  dedupe_key TEXT NOT NULL DEFAULT '',

  status TEXT NOT NULL DEFAULT 'pending'
    CHECK(status IN ('pending', 'running', 'completed', 'failed', 'cancelled')),
  error TEXT,

  content_markdown TEXT,
  source_ids_json TEXT NOT NULL DEFAULT '[]',
  citations_json TEXT NOT NULL DEFAULT '[]',
  config_json TEXT NOT NULL DEFAULT '{}',

  created_at_ms INTEGER NOT NULL,
  updated_at_ms INTEGER NOT NULL,
  started_at_ms INTEGER,
  finished_at_ms INTEGER,

  FOREIGN KEY(collection_id) REFERENCES collections(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_artifacts_collection_updated
  ON artifacts(collection_id, updated_at_ms DESC);

CREATE INDEX IF NOT EXISTS idx_artifacts_collection_type_updated
  ON artifacts(collection_id, type, updated_at_ms DESC);

CREATE INDEX IF NOT EXISTS idx_artifacts_status_updated
  ON artifacts(status, updated_at_ms DESC);

COMMIT;
"""

private final class SQLiteDatabase {
    private let handle: OpaquePointer?

    init(url: URL) throws {
        var dbHandle: OpaquePointer?
        let path = url.path
        if sqlite3_open_v2(path, &dbHandle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) != SQLITE_OK {
            defer { sqlite3_close(dbHandle) }
            let message = dbHandle.flatMap { String(cString: sqlite3_errmsg($0)) } ?? "sqlite_open_failed"
            throw CollectionStoreError.sqliteFailure(message)
        }
        handle = dbHandle
        try exec(sql: "PRAGMA foreign_keys = ON;")
        try exec(sql: "PRAGMA journal_mode = WAL;")
        try exec(sql: "PRAGMA synchronous = NORMAL;")
        try exec(sql: "PRAGMA busy_timeout = 2000;")
    }

    deinit {
        if let handle {
            sqlite3_close(handle)
        }
    }

    func exec(sql: String) throws {
        guard let handle else {
            throw CollectionStoreError.sqliteFailure("sqlite_not_open")
        }
        if sqlite3_exec(handle, sql, nil, nil, nil) != SQLITE_OK {
            throw CollectionStoreError.sqliteFailure(lastErrorMessage())
        }
    }

    func prepare(_ sql: String) throws -> OpaquePointer {
        guard let handle else {
            throw CollectionStoreError.sqliteFailure("sqlite_not_open")
        }
        var statement: OpaquePointer?
        if sqlite3_prepare_v2(handle, sql, -1, &statement, nil) != SQLITE_OK {
            throw CollectionStoreError.sqliteFailure(lastErrorMessage())
        }
        guard let prepared = statement else {
            throw CollectionStoreError.sqliteFailure("sqlite_prepare_failed")
        }
        return prepared
    }

    func step(_ statement: OpaquePointer) throws {
        let result = sqlite3_step(statement)
        if result != SQLITE_DONE {
            throw CollectionStoreError.sqliteFailure(lastErrorMessage())
        }
    }

    func lastErrorMessage() -> String {
        guard let handle else {
            return "sqlite_not_open"
        }
        return String(cString: sqlite3_errmsg(handle))
    }

    func changes() -> Int {
        guard let handle else {
            return 0
        }
        return Int(sqlite3_changes(handle))
    }

    func columnText(_ statement: OpaquePointer, index: Int32) -> String {
        guard let text = sqlite3_column_text(statement, index) else {
            return ""
        }
        return String(cString: text)
    }

    func columnOptionalText(_ statement: OpaquePointer, index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else {
            return nil
        }
        return columnText(statement, index: index)
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
