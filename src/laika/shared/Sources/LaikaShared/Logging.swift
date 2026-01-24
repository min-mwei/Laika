import Foundation

public enum LaikaPaths {
    private static let homeFolderName = "Laika"
    private static let logsFolderName = "logs"
    private static let dbFolderName = "db"
    private static let auditFolderName = "audit"
    private static let homeOverrideKey = "LAIKA_HOME"
    private static let fallbackFolderName = "Laika"
    private static var cachedHomeDirectory: URL?
    public private(set) static var lastEnsureError: String?
    public private(set) static var lastResolvedDirectory: URL?
    public private(set) static var lastPreferredDirectory: URL?
    public private(set) static var lastUsedFallback = false

    public static func homeDirectory() -> URL {
        if let cached = cachedHomeDirectory {
            return cached
        }
        if !isSandboxed, let override = overrideDirectory() {
            return override
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(homeFolderName, isDirectory: true)
    }

    @discardableResult
    public static func ensureHomeDirectory() -> URL? {
        if let cached = cachedHomeDirectory {
            lastPreferredDirectory = preferredHomeDirectory()
            lastResolvedDirectory = cached
            lastUsedFallback = lastPreferredDirectory != nil && cached.path != lastPreferredDirectory?.path
            return cached
        }
        lastPreferredDirectory = preferredHomeDirectory()
        lastResolvedDirectory = nil
        lastUsedFallback = false
        lastEnsureError = nil
        var preferredError: String?
        if let preferred = lastPreferredDirectory {
            if let error = ensureDirectories(at: preferred) {
                preferredError = error
            } else {
                cachedHomeDirectory = preferred
                lastResolvedDirectory = preferred
                return preferred
            }
        }
        var seen: Set<String> = []
        if let preferred = lastPreferredDirectory {
            seen.insert(preferred.path)
        }
        for candidate in candidateDirectories() {
            if seen.contains(candidate.path) {
                continue
            }
            seen.insert(candidate.path)
            if let error = ensureDirectories(at: candidate) {
                if preferredError == nil {
                    preferredError = error
                }
                continue
            }
            cachedHomeDirectory = candidate
            lastResolvedDirectory = candidate
            lastUsedFallback = true
            lastEnsureError = preferredError
            return candidate
        }
        lastEnsureError = preferredError
        return nil
    }

    public static func logsDirectory() -> URL? {
        guard let home = ensureHomeDirectory() else {
            return nil
        }
        return home.appendingPathComponent(logsFolderName, isDirectory: true)
    }

    public static func logFileURL(_ name: String) -> URL? {
        guard let logs = logsDirectory() else {
            return nil
        }
        return logs.appendingPathComponent(name, isDirectory: false)
    }

    public static func preferredHomeDirectory() -> URL? {
        if !isSandboxed, let override = overrideDirectory() {
            return override
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(homeFolderName, isDirectory: true)
    }

    private static func overrideDirectory() -> URL? {
        guard let raw = ProcessInfo.processInfo.environment[homeOverrideKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        else {
            return nil
        }
        let expanded = (raw as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }

    private static func candidateDirectories() -> [URL] {
        var candidates: [URL] = []
        if !isSandboxed, let override = overrideDirectory() {
            candidates.append(override)
        }
        candidates.append(FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(homeFolderName, isDirectory: true))
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            candidates.append(appSupport.appendingPathComponent(fallbackFolderName, isDirectory: true))
        }
        return candidates
    }

    private static var isSandboxed: Bool {
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        return homePath.contains("/Library/Containers/") || homePath.contains("/Library/Group Containers/")
    }

    private static func ensureDirectories(at base: URL) -> String? {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: base.appendingPathComponent(logsFolderName, isDirectory: true),
                                            withIntermediateDirectories: true)
            try fileManager.createDirectory(at: base.appendingPathComponent(dbFolderName, isDirectory: true),
                                            withIntermediateDirectories: true)
            try fileManager.createDirectory(at: base.appendingPathComponent(auditFolderName, isDirectory: true),
                                            withIntermediateDirectories: true)
            return nil
        } catch {
            return "Failed to create \(base.path): \(error.localizedDescription)"
        }
    }
}

public struct LLMTraceEvent: Codable, Sendable {
    public let type: String
    public let stage: String?
    public let id: String
    public let timestamp: Date
    public let runId: String?
    public let step: Int?
    public let maxSteps: Int?
    public let modelPath: String
    public let maxTokens: Int
    public let temperature: Double
    public let topP: Double
    public let goalPreview: String?
    public let origin: String?
    public let pageURL: String?
    public let pageTitlePreview: String?
    public let systemPromptChars: Int?
    public let userPromptChars: Int?
    public let observationChars: Int?
    public let elementCount: Int?
    public let blockCount: Int?
    public let itemCount: Int?
    public let outlineCount: Int?
    public let primaryChars: Int?
    public let commentCount: Int?
    public let tabCount: Int?
    public let recentToolCallsCount: Int?
    public let recentToolName: String?
    public let recentToolArgumentsPreview: String?
    public let recentToolResultStatus: String?
    public let recentToolResultPreview: String?
    public let promptPreview: String?
    public let outputChars: Int?
    public let outputPreview: String?
    public let toolCallsCount: Int?
    public let summaryPreview: String?
    public let error: String?

    public static func request(
        id: String,
        runId: String?,
        step: Int?,
        maxSteps: Int?,
        goal: String,
        origin: String,
        pageURL: String,
        pageTitle: String,
        recentToolCallsCount: Int,
        modelPath: String,
        maxTokens: Int,
        temperature: Double,
        topP: Double,
        systemPrompt: String,
        userPrompt: String,
        observationChars: Int,
        elementCount: Int,
        blockCount: Int,
        itemCount: Int,
        outlineCount: Int,
        primaryChars: Int,
        commentCount: Int,
        tabCount: Int,
        recentToolName: String? = nil,
        recentToolArgumentsPreview: String? = nil,
        recentToolResultStatus: String? = nil,
        recentToolResultPreview: String? = nil,
        stage: String? = "plan"
    ) -> LLMTraceEvent {
        let shouldLog = LaikaLogger.shouldLogFullLLM
        let promptPreview = shouldLog ? LaikaLogger.preview("SYSTEM:\n\(systemPrompt)\nUSER:\n\(userPrompt)") : nil
        return LLMTraceEvent(
            type: "request",
            stage: stage,
            id: id,
            timestamp: Date(),
            runId: runId,
            step: step,
            maxSteps: maxSteps,
            modelPath: modelPath,
            maxTokens: maxTokens,
            temperature: temperature,
            topP: topP,
            goalPreview: shouldLog ? LaikaLogger.preview(goal, maxChars: 200) : nil,
            origin: origin,
            pageURL: pageURL,
            pageTitlePreview: shouldLog ? LaikaLogger.preview(pageTitle, maxChars: 200) : nil,
            systemPromptChars: systemPrompt.count,
            userPromptChars: userPrompt.count,
            observationChars: observationChars,
            elementCount: elementCount,
            blockCount: blockCount,
            itemCount: itemCount,
            outlineCount: outlineCount,
            primaryChars: primaryChars,
            commentCount: commentCount,
            tabCount: tabCount,
            recentToolCallsCount: recentToolCallsCount,
            recentToolName: recentToolName,
            recentToolArgumentsPreview: recentToolArgumentsPreview,
            recentToolResultStatus: recentToolResultStatus,
            recentToolResultPreview: recentToolResultPreview,
            promptPreview: promptPreview,
            outputChars: nil,
            outputPreview: nil,
            toolCallsCount: nil,
            summaryPreview: nil,
            error: nil
        )
    }

    public static func response(
        id: String,
        runId: String?,
        step: Int?,
        maxSteps: Int?,
        modelPath: String,
        maxTokens: Int,
        temperature: Double,
        topP: Double,
        output: String,
        toolCallsCount: Int?,
        summary: String?,
        error: String?,
        stage: String? = "plan"
    ) -> LLMTraceEvent {
        let shouldLog = LaikaLogger.shouldLogFullLLM
        let outputPreview = shouldLog ? LaikaLogger.preview(output) : nil
        let summaryPreview = shouldLog ? LaikaLogger.preview(summary ?? "") : nil
        return LLMTraceEvent(
            type: "response",
            stage: stage,
            id: id,
            timestamp: Date(),
            runId: runId,
            step: step,
            maxSteps: maxSteps,
            modelPath: modelPath,
            maxTokens: maxTokens,
            temperature: temperature,
            topP: topP,
            goalPreview: nil,
            origin: nil,
            pageURL: nil,
            pageTitlePreview: nil,
            systemPromptChars: nil,
            userPromptChars: nil,
            observationChars: nil,
            elementCount: nil,
            blockCount: nil,
            itemCount: nil,
            outlineCount: nil,
            primaryChars: nil,
            commentCount: nil,
            tabCount: nil,
            recentToolCallsCount: nil,
            recentToolName: nil,
            recentToolArgumentsPreview: nil,
            recentToolResultStatus: nil,
            recentToolResultPreview: nil,
            promptPreview: nil,
            outputChars: output.count,
            outputPreview: outputPreview,
            toolCallsCount: toolCallsCount,
            summaryPreview: summaryPreview,
            error: error
        )
    }
}

public enum LaikaLogger {
    public static let shouldLogFullLLM: Bool = {
        guard let raw = ProcessInfo.processInfo.environment["LAIKA_LOG_FULL_LLM"]?.lowercased() else {
            return true
        }
        if raw == "0" || raw == "false" || raw == "no" {
            return false
        }
        return true
    }()

    public static func logLLMEvent(_ event: LLMTraceEvent) {
        guard let url = LaikaPaths.logFileURL("llm.jsonl") else {
            return
        }
        Task {
            await LaikaLogWriter.shared.append(event, to: url)
        }
    }

    public static func logAgentEvent(
        type: String,
        runId: String?,
        step: Int?,
        maxSteps: Int?,
        payload: [String: JSONValue]
    ) {
        guard let url = LaikaPaths.logFileURL("llm.jsonl") else {
            return
        }
        var enriched = payload
        if let runId, !runId.isEmpty {
            enriched["runId"] = .string(runId)
        }
        if let step {
            enriched["step"] = .number(Double(step))
        }
        if let maxSteps {
            enriched["maxSteps"] = .number(Double(maxSteps))
        }
        let event = RunEvent(type: type, payload: .object(enriched))
        Task {
            await LaikaLogWriter.shared.append(event, to: url)
        }
    }

    public static func preview(_ text: String, maxChars: Int = 1000) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count <= maxChars {
            return trimmed
        }
        let headCount = maxChars / 2
        let tailCount = maxChars - headCount
        let head = trimmed.prefix(headCount)
        let tail = trimmed.suffix(tailCount)
        return "\(head)...\(tail)"
    }
}

public actor LaikaLogWriter {
    public static let shared = LaikaLogWriter()
    private var handles: [URL: FileHandle] = [:]

    public func append<T: Encodable>(_ value: T, to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do {
            let payload = try encoder.encode(value)
            var line = payload
            line.append(0x0A)
            try write(line, to: url)
        } catch {
            return
        }
    }

    private func write(_ data: Data, to url: URL) throws {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        }
        let handle: FileHandle
        if let cached = handles[url] {
            handle = cached
        } else {
            handle = try FileHandle(forWritingTo: url)
            handles[url] = handle
        }
        handle.seekToEndOfFile()
        handle.write(data)
    }
}
