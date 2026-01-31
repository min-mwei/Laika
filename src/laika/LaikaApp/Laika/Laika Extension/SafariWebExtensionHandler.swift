//
//  SafariWebExtensionHandler.swift
//  Laika Extension
//
//  Created by Min Wei on 1/16/26.
//

import LaikaAgentCore
import LaikaModel
import LaikaShared
import SafariServices
import os.log

private let log = OSLog(subsystem: "com.laika.Laika", category: "native")
private let sharedAgent = NativeAgent()
private let sharedCollections = CollectionStore()
private let collectionContextMaxChars = 80_000
private let collectionSourceMaxChars = 8_000
private let collectionSummaryMaxSources = 12

private actor NativeAgent {
    private var modelURL: URL?
    private var runner: ModelRunner?
    private var orchestrator: AgentOrchestrator?
    private var maxTokensOverride: Int?

    func plan(request: PlanRequest, maxTokens: Int?) async throws -> AgentResponse {
        try request.validate()
        if LaikaPaths.ensureHomeDirectory() == nil {
            let error = LaikaPaths.lastEnsureError ?? "unknown"
            os_log("Failed to create Laika home directory: %{public}@", log: log, type: .error, error)
        } else if LaikaPaths.lastUsedFallback {
            let resolved = LaikaPaths.lastResolvedDirectory?.path ?? "unknown"
            let preferred = LaikaPaths.lastPreferredDirectory?.path ?? "unknown"
            let error = LaikaPaths.lastEnsureError ?? "unknown"
            os_log("Laika home fallback used (resolved=%{public}@ preferred=%{public}@ error=%{public}@)",
                   log: log,
                   type: .error,
                   resolved,
                   preferred,
                   error)
        }
        os_log(
            "Plan request origin=%{public}@ mode=%{public}@ textChars=%{public}d elements=%{public}d",
            log: log,
            type: .info,
            request.context.origin,
            String(describing: request.context.mode),
            request.context.observation.text.count,
            request.context.observation.elements.count
        )
        let nextRunner = ensureRunner(maxTokens: maxTokens)
        let response = try await orchestrator!.runOnce(context: request.context, userGoal: request.goal)
        os_log("Plan response actions=%{public}d", log: log, type: .info, response.actions.count)
        return response
    }

    func answer(request: LLMCPRequest, logContext: AnswerLogContext, maxTokens: Int?) async throws -> ModelResponse {
        let runner = ensureRunner(maxTokens: maxTokens)
        return try await runner.generateAnswer(request: request, logContext: logContext)
    }

    private func contextWithGoalPlan(_ context: ContextPack, goalPlan: GoalPlan) -> ContextPack {
        if context.goalPlan == goalPlan {
            return context
        }
        return ContextPack(
            origin: context.origin,
            mode: context.mode,
            observation: context.observation,
            recentToolCalls: context.recentToolCalls,
            recentToolResults: context.recentToolResults,
            tabs: context.tabs,
            goalPlan: goalPlan,
            runId: context.runId,
            step: context.step,
            maxSteps: context.maxSteps
        )
    }

    private func normalizeMaxTokens(_ maxTokens: Int?) -> Int {
        let defaultTokens = 2048
        let maxCap = 8192
        let minTokens = 64
        let value = maxTokens ?? defaultTokens
        return min(max(value, minTokens), maxCap)
    }

    @discardableResult
    private func ensureRunner(maxTokens: Int?) -> ModelRunner {
        let resolvedURL = resolveModelURL()
        let tokens = normalizeMaxTokens(maxTokens)
        let maxTokenCap = 8192
        let nextRunner: ModelRunner
        if let resolvedURL {
            if runner == nil || modelURL != resolvedURL {
                os_log(
                    "Using MLX model at %{public}@ (maxTokensCap=%{public}d)",
                    log: log,
                    type: .info,
                    resolvedURL.path,
                    maxTokenCap
                )
                runner = ModelRouter(preferred: .mlx, modelURL: resolvedURL, maxTokens: maxTokenCap)
                modelURL = resolvedURL
                orchestrator = nil
            }
            nextRunner = runner ?? StaticModelRunner()
        } else {
            os_log("No model directory found; using static fallback", log: log, type: .info)
            let fallback = StaticModelRunner()
            runner = fallback
            modelURL = nil
            orchestrator = nil
            nextRunner = fallback
        }

        if let configurable = nextRunner as? MaxTokenConfigurable {
            configurable.setMaxTokensOverride(tokens)
        }
        if maxTokensOverride != tokens {
            os_log(
                "Applying maxTokens override=%{public}d",
                log: log,
                type: .info,
                tokens
            )
            maxTokensOverride = tokens
        }

        if orchestrator == nil {
            orchestrator = AgentOrchestrator(model: nextRunner)
        }
        return nextRunner
    }

    private func resolveModelURL() -> URL? {
        if let resourceURL = Bundle.main.resourceURL {
            let bundledURL = resourceURL
                .appendingPathComponent("lib", isDirectory: true)
                .appendingPathComponent("models", isDirectory: true)
                .appendingPathComponent("Qwen3-0.6B-MLX-4bit", isDirectory: true)
            if FileManager.default.fileExists(atPath: bundledURL.path) {
                os_log("Bundled model found: %{public}@", log: log, type: .info, bundledURL.path)
                return bundledURL
            }
            os_log("Bundled model missing: %{public}@", log: log, type: .info, bundledURL.path)
        }
        if let envPath = ProcessInfo.processInfo.environment["LAIKA_MODEL_DIR"], !envPath.isEmpty {
            let url = URL(fileURLWithPath: envPath)
            if FileManager.default.fileExists(atPath: url.path) {
                os_log("Model env path found: %{public}@", log: log, type: .info, url.path)
                return url
            }
            os_log("Model env path missing: %{public}@", log: log, type: .info, url.path)
        }
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let defaultURL = appSupport
                .appendingPathComponent("Laika", isDirectory: true)
                .appendingPathComponent("Models", isDirectory: true)
                .appendingPathComponent("Qwen3-0.6B-MLX-4bit", isDirectory: true)
            if FileManager.default.fileExists(atPath: defaultURL.path) {
                os_log("Model default path found: %{public}@", log: log, type: .info, defaultURL.path)
                return defaultURL
            }
            os_log("Model default path missing: %{public}@", log: log, type: .info, defaultURL.path)
        }
        return nil
    }
}

class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
    private let agent = sharedAgent

    func beginRequest(with context: NSExtensionContext) {
        let request = context.inputItems.first as? NSExtensionItem

        let profile: UUID?
        if #available(iOS 17.0, macOS 14.0, *) {
            profile = request?.userInfo?[SFExtensionProfileKey] as? UUID
        } else {
            profile = request?.userInfo?["profile"] as? UUID
        }

        let message: Any?
        if #available(iOS 15.0, macOS 11.0, *) {
            message = request?.userInfo?[SFExtensionMessageKey]
        } else {
            message = request?.userInfo?["message"]
        }

        os_log("Received native message (profile: %{public}@)", log: log, type: .info, profile?.uuidString ?? "none")

        Task {
            let responsePayload = await handleMessage(message)
            let responseItem = NSExtensionItem()
            if #available(iOS 15.0, macOS 11.0, *) {
                responseItem.userInfo = [SFExtensionMessageKey: responsePayload]
            } else {
                responseItem.userInfo = ["message": responsePayload]
            }
            context.completeRequest(returningItems: [responseItem], completionHandler: nil)
        }
    }

    private func handleMessage(_ message: Any?) async -> [String: Any] {
        guard let dict = message as? [String: Any],
              let type = dict["type"] as? String else {
            os_log("Invalid native message payload", log: log, type: .error)
            return ["ok": false, "error": "invalid_message"]
        }

        if LaikaPaths.ensureHomeDirectory() == nil {
            let error = LaikaPaths.lastEnsureError ?? "unknown"
            os_log("Failed to create Laika home directory: %{public}@", log: log, type: .error, error)
        }

        os_log("Native message type=%{public}@", log: log, type: .info, type)
        if type == "ping" {
            return ["ok": true, "status": "ready"]
        }

        if type == "collection" {
            return await handleCollectionMessage(dict)
        }

        if type == "tool" {
            return await handleToolMessage(dict)
        }

        guard type == "plan" else {
            os_log("Unsupported native message type=%{public}@", log: log, type: .error, type)
            return ["ok": false, "error": "unsupported_type"]
        }

        guard let requestPayload = dict["request"] else {
            os_log("Missing request payload", log: log, type: .error)
            return ["ok": false, "error": "missing_request"]
        }

        let messageStartedAt = Date()
        do {
            guard JSONSerialization.isValidJSONObject(requestPayload) else {
                os_log("Plan request payload is not valid JSON", log: log, type: .error)
                return ["ok": false, "error": "invalid_request_payload"]
            }
            let data = try JSONSerialization.data(withJSONObject: requestPayload, options: [])
            let planRequest = try JSONDecoder().decode(PlanRequest.self, from: data)
            let maxTokens = (dict["maxTokens"] as? NSNumber)?.intValue
            LaikaLogger.logAgentEvent(
                type: "native.plan_request",
                runId: planRequest.context.runId,
                step: planRequest.context.step,
                maxSteps: planRequest.context.maxSteps,
                payload: [
                    "goalPreview": .string(LaikaLogger.preview(planRequest.goal, maxChars: 200)),
                    "origin": .string(planRequest.context.origin),
                    "pageURL": .string(planRequest.context.observation.url),
                    "requestBytes": .number(Double(data.count)),
                    "observationChars": .number(Double(planRequest.context.observation.text.count)),
                    "elementCount": .number(Double(planRequest.context.observation.elements.count)),
                    "itemCount": .number(Double(planRequest.context.observation.items.count)),
                    "commentCount": .number(Double(planRequest.context.observation.comments.count)),
                    "tabCount": .number(Double(planRequest.context.tabs.count))
                ]
            )
            let planStartedAt = Date()
            let response = try await agent.plan(request: planRequest, maxTokens: maxTokens)
            let planDurationMs = max(0, Date().timeIntervalSince(planStartedAt) * 1000)
            let totalDurationMs = max(0, Date().timeIntervalSince(messageStartedAt) * 1000)
            LaikaLogger.logAgentEvent(
                type: "native.plan_response",
                runId: planRequest.context.runId,
                step: planRequest.context.step,
                maxSteps: planRequest.context.maxSteps,
                payload: [
                    "ok": .bool(true),
                    "planDurationMs": .number(planDurationMs),
                    "totalDurationMs": .number(totalDurationMs),
                    "actions": .number(Double(response.actions.count)),
                    "summaryChars": .number(Double(response.summary.count))
                ]
            )
            let jsonData = try JSONEncoder().encode(response)
            let jsonObject = try JSONSerialization.jsonObject(with: jsonData, options: [])
            return ["ok": true, "plan": jsonObject]
        } catch let error as PlanValidationError {
            os_log("Plan validation error: %{public}@", log: log, type: .error, error.localizedDescription)
            return ["ok": false, "error": error.localizedDescription]
        } catch {
            os_log("Plan error: %{public}@", log: log, type: .error, error.localizedDescription)
            let durationMs = max(0, Date().timeIntervalSince(messageStartedAt) * 1000)
            LaikaLogger.logAgentEvent(
                type: "native.plan_response",
                runId: nil,
                step: nil,
                maxSteps: nil,
                payload: [
                    "ok": .bool(false),
                    "totalDurationMs": .number(durationMs),
                    "error": .string(error.localizedDescription)
                ]
            )
            return ["ok": false, "error": error.localizedDescription]
        }
    }

    private func handleCollectionMessage(_ message: [String: Any]) async -> [String: Any] {
        guard let action = message["action"] as? String else {
            return ["ok": false, "error": "missing_action"]
        }
        let payload = message["payload"] ?? message
        return await handleCollectionAction(action: action, payload: payload)
    }

    private func handleToolMessage(_ message: [String: Any]) async -> [String: Any] {
        guard let toolNameRaw = message["toolName"] as? String,
              let toolName = ToolName(rawValue: toolNameRaw) else {
            return ["ok": false, "error": "unknown_tool"]
        }
        let arguments = message["arguments"] ?? [:]
        do {
            let argumentsData = try encodeJSONPayload(arguments)
            let decodedArguments = try JSONDecoder().decode([String: JSONValue].self, from: argumentsData)
            if !ToolSchemaValidator.validateArguments(name: toolName, arguments: decodedArguments) {
                return ["ok": false, "error": "invalid_arguments"]
            }
            switch toolName {
            case .collectionCreate:
                let payload = try JSONDecoder().decode(CollectionCreatePayload.self, from: argumentsData)
                return await handleCollectionAction(action: "create", payload: payload)
            case .collectionAddSources:
                let payload = try JSONDecoder().decode(CollectionAddSourcesPayload.self, from: argumentsData)
                return await handleCollectionAction(action: "add_sources", payload: payload)
            case .collectionListSources:
                let payload = try JSONDecoder().decode(CollectionListSourcesPayload.self, from: argumentsData)
                return await handleCollectionAction(action: "list_sources", payload: payload)
            case .sourceCapture:
                return ["ok": true, "result": ["status": "error", "error": "not_implemented"]]
            case .sourceRefresh:
                return ["ok": true, "result": ["status": "error", "error": "not_implemented"]]
            case .transformListTypes:
                return ["ok": true, "result": ["status": "ok", "types": []]]
            case .transformRun:
                return ["ok": true, "result": ["status": "error", "error": "not_implemented"]]
            case .artifactSave:
                return ["ok": true, "result": ["status": "error", "error": "not_implemented"]]
            case .artifactOpen:
                return ["ok": true, "result": ["status": "error", "error": "not_implemented"]]
            case .artifactShare:
                return ["ok": true, "result": ["status": "error", "error": "not_implemented"]]
            case .integrationInvoke:
                return ["ok": true, "result": ["status": "error", "error": "not_implemented"]]
            default:
                return ["ok": false, "error": "unsupported_tool"]
            }
        } catch {
            let message: String
            if let collectionError = error as? CollectionStoreError {
                message = collectionError.description
            } else {
                message = String(describing: error)
            }
            return ["ok": false, "error": message]
        }
    }

    private func handleCollectionAction(action: String, payload: Any) async -> [String: Any] {
        do {
            switch action {
            case "list":
                let result = try await sharedCollections.listCollections()
                let collections = result.collections.map { collectionPayload($0) }
                var response: [String: Any] = ["status": "ok", "collections": collections]
                if let activeId = result.activeCollectionId {
                    response["activeCollectionId"] = activeId
                }
                return ["ok": true, "result": response]
            case "create":
                let payload = try decodePayload(CollectionCreatePayload.self, from: payload)
                let record = try await sharedCollections.createCollection(title: payload.title, tags: payload.tags ?? [])
                let result: [String: Any] = [
                    "status": "ok",
                    "collection": collectionPayload(record),
                    "activeCollectionId": record.id
                ]
                return ["ok": true, "result": result]
            case "set_active":
                let payload = try decodePayload(CollectionSetActivePayload.self, from: payload)
                try await sharedCollections.setActiveCollection(payload.collectionId)
                var result: [String: Any] = ["status": "ok"]
                if let activeId = payload.collectionId {
                    result["activeCollectionId"] = activeId
                }
                return ["ok": true, "result": result]
            case "list_sources":
                let payload = try decodePayload(CollectionListSourcesPayload.self, from: payload)
                let sources = try await sharedCollections.listSources(collectionId: payload.collectionId)
                let result: [String: Any] = [
                    "status": "ok",
                    "sources": sources.map { sourcePayload($0) }
                ]
                return ["ok": true, "result": result]
            case "next_capture_job":
                let payload = try decodePayload(CollectionNextCaptureJobPayload.self, from: payload)
                let job = try await sharedCollections.claimNextCaptureJob(collectionId: payload.collectionId)
                var result: [String: Any] = ["status": "ok"]
                if let job {
                    result["job"] = captureJobPayload(job)
                }
                return ["ok": true, "result": result]
            case "add_sources":
                let payload = try decodePayload(CollectionAddSourcesPayload.self, from: payload)
                let resultValue = try await sharedCollections.addSources(collectionId: payload.collectionId, sources: payload.sources)
                let result: [String: Any] = [
                    "status": "ok",
                    "sources": resultValue.sources.map { sourcePayload($0) },
                    "ignoredCount": resultValue.ignoredCount,
                    "dedupedCount": resultValue.dedupedCount
                ]
                return ["ok": true, "result": result]
            case "delete":
                let payload = try decodePayload(CollectionDeletePayload.self, from: payload)
                let nextActive = try await sharedCollections.deleteCollection(collectionId: payload.collectionId)
                var result: [String: Any] = ["status": "ok"]
                if let nextActive {
                    result["activeCollectionId"] = nextActive
                }
                return ["ok": true, "result": result]
            case "delete_source":
                let payload = try decodePayload(CollectionDeleteSourcePayload.self, from: payload)
                try await sharedCollections.deleteSource(collectionId: payload.collectionId, sourceId: payload.sourceId)
                return ["ok": true, "result": ["status": "ok"]]
            case "capture_update":
                let payload = try decodePayload(CollectionCaptureUpdatePayload.self, from: payload)
                switch payload.status {
                case "captured":
                    guard let markdown = payload.markdown else {
                        throw CollectionStoreError.invalidRequest("capture_markdown_required")
                    }
                    try await sharedCollections.markSourceCaptured(
                        collectionId: payload.collectionId,
                        url: payload.url,
                        title: payload.title,
                        markdown: markdown,
                        links: payload.links ?? []
                    )
                case "failed":
                    let errorMessage = (payload.error ?? "").isEmpty ? "capture_failed" : payload.error!
                    try await sharedCollections.markSourceCaptureFailed(
                        collectionId: payload.collectionId,
                        url: payload.url,
                        error: errorMessage
                    )
                default:
                    throw CollectionStoreError.invalidRequest("invalid_capture_status")
                }
                return ["ok": true, "result": ["status": "ok"]]
            case "answer":
                let payload = try decodePayload(CollectionAnswerPayload.self, from: payload)
                let question = payload.question.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !question.isEmpty else {
                    throw CollectionStoreError.invalidRequest("question_required")
                }
                guard let collection = try await sharedCollections.getCollection(collectionId: payload.collectionId) else {
                    throw CollectionStoreError.invalidRequest("collection_not_found")
                }
                let maxSources = max(1, min(payload.maxSources ?? 10, 20))
                let snapshots = try await sharedCollections.listSourceSnapshots(
                    collectionId: payload.collectionId,
                    limit: maxSources
                )
                let capturedSources = snapshots.filter { !$0.captureMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                guard !capturedSources.isEmpty else {
                    throw CollectionStoreError.invalidRequest("no_captured_sources")
                }
                let preparedQuestion = prepareCollectionQuestion(question, sources: capturedSources)
                let runId = "collection:\(payload.collectionId)"
                let turn = max(1, (try await sharedCollections.listChatEvents(collectionId: payload.collectionId, limit: 200).count + 1))
                let (request, logContext, citationMap) = buildCollectionAnswerRequest(
                    collection: collection,
                    sources: capturedSources,
                    question: preparedQuestion,
                    runId: runId,
                    turn: turn
                )
                let requestStartedAt = Date()
                LaikaLogger.logAgentEvent(
                    type: "native.collection_answer_request",
                    runId: runId,
                    step: nil,
                    maxSteps: nil,
                    payload: [
                        "collectionId": .string(payload.collectionId),
                        "questionPreview": .string(LaikaLogger.preview(question, maxChars: 200)),
                        "preparedQuestionPreview": .string(LaikaLogger.preview(preparedQuestion, maxChars: 200)),
                        "sourceIds": .array(capturedSources.prefix(12).map { .string($0.id) }),
                        "sourceTitles": .array(capturedSources.prefix(12).map {
                            let title = $0.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                            return .string(LaikaLogger.preview(title.isEmpty ? $0.url : title, maxChars: 120))
                        }),
                        "sourceCount": .number(Double(capturedSources.count)),
                        "contextChars": .number(Double(logContext.contextChars))
                    ]
                )
                let userEvent = try await sharedCollections.addChatEvent(
                    collectionId: payload.collectionId,
                    role: "user",
                    markdown: question
                )
                var response = try await agent.answer(request: request, logContext: logContext, maxTokens: payload.maxTokens)
                var citationsPayload = buildCitationPayload(response: response, sourceURLMap: citationMap)
                var assistantMarkdown = response.assistant.render.markdown()
                if let rawMarkdown = response.rawMarkdown, !rawMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    assistantMarkdown = rawMarkdown
                }
                if assistantMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let summary = response.summary.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !summary.isEmpty {
                        assistantMarkdown = summary
                    } else {
                        let fallback = response.assistant.render.plainText().trimmingCharacters(in: .whitespacesAndNewlines)
                        assistantMarkdown = fallback.isEmpty ? "Answer unavailable." : fallback
                    }
                }
                if shouldEnforceCoverage(question: question) {
                    let missing = missingCoverageSources(sources: capturedSources, answerMarkdown: assistantMarkdown, citations: response.assistant.citations)
                    if !missing.isEmpty {
                        let repairQuestion = prepareCoverageRepairQuestion(
                            original: question,
                            sources: capturedSources,
                            missing: missing,
                            previousAnswer: assistantMarkdown
                        )
                        LaikaLogger.logAgentEvent(
                            type: "native.collection_answer_retry",
                            runId: runId,
                            step: nil,
                            maxSteps: nil,
                            payload: [
                                "missingCount": .number(Double(missing.count)),
                                "retrySourceCount": .number(Double(missing.count)),
                                "missingTitles": .array(missing.prefix(10).map {
                                    let title = $0.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                                    return .string(LaikaLogger.preview(title.isEmpty ? $0.url : title, maxChars: 120))
                                })
                            ]
                        )
                        let (retryRequest, retryLogContext, retryCitationMap) = buildCollectionAnswerRequest(
                            collection: collection,
                            sources: missing,
                            question: repairQuestion,
                            runId: runId,
                            turn: turn
                        )
                        let retryResponse = try await agent.answer(request: retryRequest, logContext: retryLogContext, maxTokens: payload.maxTokens)
                        response = retryResponse
                        let retryCitations = buildCitationPayload(response: retryResponse, sourceURLMap: retryCitationMap)
                        citationsPayload = mergeCitations(existing: citationsPayload, additional: retryCitations)
                        assistantMarkdown = retryResponse.assistant.render.markdown()
                        if let rawMarkdown = retryResponse.rawMarkdown,
                           !rawMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            assistantMarkdown = rawMarkdown
                        }
                        if assistantMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            let summary = retryResponse.summary.trimmingCharacters(in: .whitespacesAndNewlines)
                            assistantMarkdown = summary.isEmpty ? "Answer unavailable." : summary
                        }
                    }
                }
                let citationsJSON = encodeJSONArrayPayload(citationsPayload)
                let assistantEvent = try await sharedCollections.addChatEvent(
                    collectionId: payload.collectionId,
                    role: "assistant",
                    markdown: assistantMarkdown,
                    citationsJSON: citationsJSON
                )
                let durationMs = max(0, Date().timeIntervalSince(requestStartedAt) * 1000)
                LaikaLogger.logAgentEvent(
                    type: "native.collection_answer_response",
                    runId: runId,
                    step: nil,
                    maxSteps: nil,
                    payload: [
                        "ok": .bool(true),
                        "durationMs": .number(durationMs),
                        "answerChars": .number(Double(assistantMarkdown.count))
                    ]
                )
                let result: [String: Any] = [
                    "status": "ok",
                    "answer": [
                        "title": response.assistant.title as Any,
                        "markdown": assistantMarkdown,
                        "citations": citationsPayload,
                        "eventId": assistantEvent.id,
                        "questionEventId": userEvent.id
                    ]
                ]
                return ["ok": true, "result": result]
            case "get_chat_event":
                let payload = try decodePayload(CollectionGetChatEventPayload.self, from: payload)
                guard let collection = try await sharedCollections.getCollection(collectionId: payload.collectionId) else {
                    throw CollectionStoreError.invalidRequest("collection_not_found")
                }
                guard let event = try await sharedCollections.getChatEvent(
                    collectionId: payload.collectionId,
                    eventId: payload.eventId
                ) else {
                    throw CollectionStoreError.invalidRequest("event_not_found")
                }
                var userEvent: ChatEventRecord?
                if let questionEventId = payload.questionEventId, !questionEventId.isEmpty {
                    userEvent = try await sharedCollections.getChatEvent(
                        collectionId: payload.collectionId,
                        eventId: questionEventId
                    )
                }
                if userEvent == nil {
                    userEvent = try await sharedCollections.getLatestUserEvent(
                        collectionId: payload.collectionId,
                        before: event.createdAtMs
                    )
                }
                var result: [String: Any] = [
                    "status": "ok",
                    "collection": collectionPayload(collection),
                    "event": chatEventPayload(event)
                ]
                if let userEvent {
                    result["userEvent"] = chatEventPayload(userEvent)
                }
                return ["ok": true, "result": result]
            case "list_chat":
                let payload = try decodePayload(CollectionListChatPayload.self, from: payload)
                let limit = max(1, min(payload.limit ?? 60, 200))
                let events = try await sharedCollections.listChatEvents(collectionId: payload.collectionId, limit: limit)
                let resultEvents: [[String: Any]] = events.map { event in
                    [
                        "id": event.id,
                        "role": event.role,
                        "markdown": event.markdown,
                        "citationsJSON": event.citationsJSON,
                        "createdAtMs": event.createdAtMs
                    ]
                }
                return ["ok": true, "result": ["status": "ok", "events": resultEvents]]
            case "clear_chat":
                let payload = try decodePayload(CollectionClearChatPayload.self, from: payload)
                try await sharedCollections.clearChatEvents(collectionId: payload.collectionId)
                return ["ok": true, "result": ["status": "ok"]]
            default:
                return ["ok": false, "error": "unknown_action"]
            }
        } catch {
            let message: String
            if let collectionError = error as? CollectionStoreError {
                message = collectionError.description
            } else {
                message = error.localizedDescription
            }
            return ["ok": false, "error": message]
        }
    }

    private func prepareCollectionQuestion(_ question: String, sources: [SourceSnapshot]) -> String {
        let trimmed = question.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return trimmed
        }
        if !isSummaryQuestion(trimmed) {
            return trimmed
        }
        let titles = sources.prefix(collectionSummaryMaxSources).map { source in
            let raw = source.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let raw, !raw.isEmpty {
                return TextUtils.truncate(TextUtils.normalizeWhitespace(raw), maxChars: 120)
            }
            return TextUtils.truncate(TextUtils.normalizeWhitespace(source.url), maxChars: 120)
        }
        let bulletList = titles.map { "- \($0)" }.joined(separator: "\n")
        let expectedCount = min(sources.count, collectionSummaryMaxSources)
        let intro = """
Summarize this collection using every source.
First write 2-3 sentences of overall context.
Then provide exactly \(expectedCount) bullet(s), one per source, using the titles below.
Each bullet must start with the exact title in quotes (verbatim) and be 1-2 sentences.
Each bullet must cite that source. If a source adds no new info, still include it and say so.
"""
        if bulletList.isEmpty {
            return intro + "\nOriginal request: " + trimmed
        }
        return intro + "\nSource titles:\n" + bulletList + "\n\nOriginal request: " + trimmed
    }

    private func prepareCoverageRepairQuestion(
        original: String,
        sources: [SourceSnapshot],
        missing: [SourceSnapshot],
        previousAnswer: String
    ) -> String {
        let missingTitles = missing.prefix(collectionSummaryMaxSources).map { source in
            let raw = source.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let raw, !raw.isEmpty {
                return TextUtils.truncate(TextUtils.normalizeWhitespace(raw), maxChars: 120)
            }
            return TextUtils.truncate(TextUtils.normalizeWhitespace(source.url), maxChars: 120)
        }
        let missingList = missingTitles.map { "- \($0)" }.joined(separator: "\n")
        let clippedAnswer = TextUtils.truncate(
            TextUtils.normalizePreservingNewlines(previousAnswer),
            maxChars: 4000
        )
        let base = """
The user asked: \(original)

Keep the previous answer verbatim. Then append coverage for the missing sources only.
Do not rewrite or remove existing content. If the original answer used bullets per source, append bullets for missing sources.
"""
        if missingList.isEmpty {
            return base
        }
        return """
\(base)

Previous answer:
\(clippedAnswer)

Missing sources to add:
\(missingList)
"""
    }

    private func mergeCitations(existing: [[String: Any]], additional: [[String: Any]]) -> [[String: Any]] {
        guard !existing.isEmpty else {
            return additional
        }
        guard !additional.isEmpty else {
            return existing
        }
        var seen: Set<String> = []
        var merged: [[String: Any]] = []
        for entry in existing + additional {
            let key = citationKey(entry)
            if seen.contains(key) {
                continue
            }
            seen.insert(key)
            merged.append(entry)
        }
        return merged
    }

    private func citationKey(_ entry: [String: Any]) -> String {
        let sourceId = (entry["source_id"] as? String) ?? ""
        let url = (entry["url"] as? String) ?? ""
        let quote = (entry["quote"] as? String) ?? ""
        let locator = (entry["locator"] as? String) ?? ""
        return "\(sourceId)|\(url)|\(quote)|\(locator)"
    }

    private func shouldEnforceCoverage(question: String) -> Bool {
        let lower = question.lowercased()
        if isSummaryQuestion(lower) {
            return true
        }
        let keywords = ["compare", "comparison", "difference", "differences", "contrast", "how does each", "how do the sources"]
        return keywords.contains { lower.contains($0) }
    }

    private func missingCoverageSources(
        sources: [SourceSnapshot],
        answerMarkdown: String,
        citations: [LLMCPCitation]
    ) -> [SourceSnapshot] {
        if sources.isEmpty {
            return []
        }
        let normalizedAnswer = TextUtils.normalizeWhitespace(answerMarkdown).lowercased()
        var citedSourceIds: Set<String> = []
        for citation in citations {
            citedSourceIds.insert(citation.docId)
        }
        return sources.filter { source in
            if citedSourceIds.contains(source.id) {
                return false
            }
            if let title = source.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
                let needle = TextUtils.truncate(TextUtils.normalizeWhitespace(title), maxChars: 80).lowercased()
                if normalizedAnswer.contains(needle) {
                    return false
                }
            }
            if let host = URL(string: source.url)?.host?.lowercased(),
               !host.isEmpty,
               normalizedAnswer.contains(host) {
                return false
            }
            return true
        }
    }

    private func isSummaryQuestion(_ question: String) -> Bool {
        let lower = question.lowercased()
        let hasSummary = lower.contains("summarize") || lower.contains("summarise") || lower.contains("summary")
        let hasCollection = lower.contains("collection") || lower.contains("sources")
        return hasSummary && hasCollection
    }

    private func buildCollectionAnswerRequest(
        collection: CollectionRecord,
        sources: [SourceSnapshot],
        question: String,
        runId: String,
        turn: Int
    ) -> (LLMCPRequest, AnswerLogContext, [String: String]) {
        let conversationId = collection.id
        let requestId = UUID().uuidString
        let input = LLMCPInput(
            userMessage: LLMCPUserMessage(id: UUID().uuidString, text: question),
            task: LLMCPTask(name: "web.answer", args: nil)
        )
        let (documents, citationMap, contextChars) = buildCollectionDocuments(collection: collection, sources: sources)
        let request = LLMCPRequest(
            protocolInfo: LLMCPProtocol(name: "laika.llmcp", version: 1),
            id: requestId,
            type: .request,
            createdAt: llmcpNowString(),
            conversation: LLMCPConversation(id: conversationId, turn: turn),
            sender: LLMCPSender(role: "agent"),
            input: input,
            context: LLMCPContext(documents: documents),
            output: LLMCPOutputSpec(format: "markdown"),
            trace: nil
        )
        let logContext = AnswerLogContext(
            runId: runId,
            step: nil,
            maxSteps: nil,
            origin: "collection",
            pageURL: "collection:\(collection.id)",
            pageTitle: collection.title,
            sourceCount: sources.count,
            contextChars: contextChars
        )
        return (request, logContext, citationMap)
    }

    private func buildCollectionDocuments(
        collection: CollectionRecord,
        sources: [SourceSnapshot]
    ) -> ([LLMCPDocument], [String: String], Int) {
        var documents: [LLMCPDocument] = []
        var citationMap: [String: String] = [:]
        var contextChars = 0

        var includedSources: [SourceSnapshot] = []
        for source in sources {
            let trimmed = source.captureMarkdown.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                continue
            }
            let boundedMarkdown = TextUtils.truncate(trimmed, maxChars: collectionSourceMaxChars)
            if !includedSources.isEmpty && contextChars + boundedMarkdown.count > collectionContextMaxChars {
                break
            }
            citationMap[source.id] = source.url
            contextChars += boundedMarkdown.count
            includedSources.append(source)
            documents.append(collectionSourceDocument(collection: collection, source: source, markdown: boundedMarkdown))
        }

        let indexDoc = collectionIndexDocument(
            collection: collection,
            sources: includedSources,
            contextNote: includedSources.count < sources.count
                ? "Context trimmed to \(includedSources.count) sources to fit budget."
                : nil
        )
        documents.insert(indexDoc, at: 0)

        return (documents, citationMap, contextChars)
    }

    private func collectionIndexDocument(
        collection: CollectionRecord,
        sources: [SourceSnapshot],
        contextNote: String?
    ) -> LLMCPDocument {
        let sourceEntries: [JSONValue] = sources.map { source in
            var entry: [String: JSONValue] = [
                "source_id": .string(source.id),
                "url": .string(source.url)
            ]
            if let title = source.title, !title.isEmpty {
                entry["title"] = .string(title)
            }
            if let capturedAt = source.capturedAtMs, let iso = isoString(fromMs: capturedAt) {
                entry["captured_at"] = .string(iso)
            }
            return .object(entry)
        }
        var content: [String: JSONValue] = [
            "doc_type": .string("collection.index.v1"),
            "collection_id": .string(collection.id),
            "title": .string(collection.title),
            "sources": .array(sourceEntries)
        ]
        if let note = contextNote, !note.isEmpty {
            content["context_note"] = .string(note)
        }
        if !collection.tags.isEmpty {
            content["tags"] = .array(collection.tags.map { .string($0) })
        }
        return LLMCPDocument(
            docId: "doc:collection:index",
            kind: "collection.index.v1",
            trust: "untrusted",
            source: nil,
            content: .object(content)
        )
    }

    private func collectionSourceDocument(
        collection: CollectionRecord,
        source: SourceSnapshot,
        markdown: String? = nil
    ) -> LLMCPDocument {
        let body = markdown ?? source.captureMarkdown
        var content: [String: JSONValue] = [
            "doc_type": .string("collection.source.v1"),
            "collection_id": .string(collection.id),
            "source_id": .string(source.id),
            "url": .string(source.url),
            "markdown": .string(body)
        ]
        if let title = source.title, !title.isEmpty {
            content["title"] = .string(title)
        }
        if let capturedAt = source.capturedAtMs, let iso = isoString(fromMs: capturedAt) {
            content["captured_at"] = .string(iso)
        }
        if !source.extractedLinks.isEmpty {
            let links = source.extractedLinks.map { link -> JSONValue in
                var entry: [String: JSONValue] = [
                    "url": .string(link.url)
                ]
                if let text = link.text, !text.isEmpty {
                    entry["text"] = .string(text)
                }
                if let context = link.context, !context.isEmpty {
                    entry["context"] = .string(context)
                }
                return .object(entry)
            }
            content["extracted_links"] = .array(links)
        }
        return LLMCPDocument(
            docId: source.id,
            kind: "collection.source.v1",
            trust: "untrusted",
            source: nil,
            content: .object(content)
        )
    }

    private func buildCitationPayload(
        response: ModelResponse,
        sourceURLMap: [String: String]
    ) -> [[String: Any]] {
        let citations = response.assistant.citations
        guard !citations.isEmpty else {
            return []
        }
        return citations.map { citation in
            var entry: [String: Any] = ["source_id": citation.docId]
            if let url = sourceURLMap[citation.docId], !url.isEmpty {
                entry["url"] = url
            }
            if let quote = citation.quote, !quote.isEmpty {
                entry["quote"] = quote
            }
            if let nodeId = citation.nodeId, !nodeId.isEmpty {
                entry["locator"] = nodeId
            } else if let handleId = citation.handleId, !handleId.isEmpty {
                entry["locator"] = handleId
            }
            return entry
        }
    }

    private func isoString(fromMs ms: Int64) -> String? {
        let date = Date(timeIntervalSince1970: Double(ms) / 1000.0)
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: date)
    }

    private func llmcpNowString() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: Date())
    }

    private func encodeJSONArrayPayload(_ array: [[String: Any]]) -> String {
        guard JSONSerialization.isValidJSONObject(array),
              let data = try? JSONSerialization.data(withJSONObject: array, options: []),
              let json = String(data: data, encoding: .utf8) else {
            return "[]"
        }
        return json
    }

    private func decodeJSONArrayPayload(_ json: String) -> [[String: Any]] {
        guard let data = json.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data, options: []),
              let array = raw as? [[String: Any]] else {
            return []
        }
        return array
    }

    private func chatEventPayload(_ record: ChatEventRecord) -> [String: Any] {
        [
            "id": record.id,
            "role": record.role,
            "markdown": record.markdown,
            "citations": decodeJSONArrayPayload(record.citationsJSON),
            "createdAtMs": record.createdAtMs
        ]
    }

    private func collectionPayload(_ record: CollectionRecord) -> [String: Any] {
        [
            "id": record.id,
            "title": record.title,
            "tags": record.tags,
            "createdAtMs": record.createdAtMs,
            "updatedAtMs": record.updatedAtMs
        ]
    }

    private func captureJobPayload(_ record: CaptureJobRecord) -> [String: Any] {
        [
            "id": record.id,
            "collectionId": record.collectionId,
            "sourceId": record.sourceId,
            "url": record.url,
            "attemptCount": record.attemptCount,
            "maxAttempts": record.maxAttempts
        ]
    }

    private func sourcePayload(_ record: SourceRecord) -> [String: Any] {
        var payload: [String: Any] = [
            "id": record.id,
            "collectionId": record.collectionId,
            "kind": record.kind.rawValue,
            "captureStatus": record.captureStatus.rawValue,
            "addedAtMs": record.addedAtMs,
            "updatedAtMs": record.updatedAtMs
        ]
        if let url = record.url {
            payload["url"] = url
        }
        if let title = record.title {
            payload["title"] = title
        }
        if let capturedAtMs = record.capturedAtMs {
            payload["capturedAtMs"] = capturedAtMs
        }
        if let captureError = record.captureError, !captureError.isEmpty {
            payload["captureError"] = captureError
        }
        return payload
    }

    private func decodePayload<T: Decodable>(_ type: T.Type, from payload: Any) throws -> T {
        let data = try encodeJSONPayload(payload)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func encodeJSONPayload(_ payload: Any) throws -> Data {
        guard JSONSerialization.isValidJSONObject(payload) else {
            throw CollectionStoreError.invalidRequest("invalid_payload")
        }
        return try JSONSerialization.data(withJSONObject: payload, options: [])
    }
}

private struct CollectionCreatePayload: Decodable {
    let title: String
    let tags: [String]?
}

private struct CollectionSetActivePayload: Decodable {
    let collectionId: String?
}

private struct CollectionListSourcesPayload: Decodable {
    let collectionId: String
}

private struct CollectionNextCaptureJobPayload: Decodable {
    let collectionId: String?
}

private struct CollectionAddSourcesPayload: Decodable {
    let collectionId: String
    let sources: [SourceInput]
}

private struct CollectionDeletePayload: Decodable {
    let collectionId: String
}

private struct CollectionDeleteSourcePayload: Decodable {
    let collectionId: String
    let sourceId: String
}

private struct CollectionCaptureUpdatePayload: Decodable {
    let collectionId: String
    let url: String
    let status: String
    let title: String?
    let markdown: String?
    let links: [CapturedLink]?
    let error: String?
}

private struct CollectionAnswerPayload: Decodable {
    let collectionId: String
    let question: String
    let maxTokens: Int?
    let maxSources: Int?
}

private struct CollectionListChatPayload: Decodable {
    let collectionId: String
    let limit: Int?
}

private struct CollectionClearChatPayload: Decodable {
    let collectionId: String
}

private struct CollectionGetChatEventPayload: Decodable {
    let collectionId: String
    let eventId: String
    let questionEventId: String?
}
