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

private actor NativeAgent {
    private var modelURL: URL?
    private var runner: ModelRunner?
    private var orchestrator: AgentOrchestrator?
    private var summaryService: SummaryService?
    private var maxTokens: Int?
    private let summaryStreams = SummaryStreamManager()

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

    func startSummaryStream(request: PlanRequest, goalPlanHint: GoalPlan?, maxTokens: Int?) async throws -> String {
        try request.validate()
        _ = ensureRunner(maxTokens: maxTokens)
        guard let orchestrator else {
            throw ModelError.modelUnavailable("Agent unavailable.")
        }
        guard let summaryService else {
            throw ModelError.modelUnavailable("Summary service unavailable.")
        }
        let resolvedGoalPlan: GoalPlan
        if let hint = goalPlanHint {
            resolvedGoalPlan = hint
        } else {
            resolvedGoalPlan = await orchestrator.resolveGoalPlan(context: request.context, userGoal: request.goal)
        }
        let wantsSummary = resolvedGoalPlan.intent == GoalPlan.Intent.pageSummary
            || resolvedGoalPlan.intent == GoalPlan.Intent.itemSummary
            || resolvedGoalPlan.intent == GoalPlan.Intent.commentSummary
            || resolvedGoalPlan.wantsComments
        guard wantsSummary else {
            throw ModelError.invalidResponse("not_summary")
        }
        let context = contextWithGoalPlan(request.context, goalPlan: resolvedGoalPlan)
        let stream = summaryService.streamSummary(
            context: context,
            goalPlan: resolvedGoalPlan,
            userGoal: request.goal,
            maxTokens: normalizeMaxTokens(maxTokens)
        )
        let streamId = UUID().uuidString
        let metadata = SummaryStreamMetadata(
            runId: context.runId,
            step: context.step,
            maxSteps: context.maxSteps,
            goalPlan: resolvedGoalPlan,
            mode: context.mode,
            origin: context.origin,
            url: context.observation.url,
            title: context.observation.title
        )
        await summaryStreams.start(id: streamId, stream: stream, metadata: metadata)
        return streamId
    }

    func pollSummaryStream(id: String) async -> SummaryStreamPollResult? {
        await summaryStreams.poll(id: id, maxChunks: 6)
    }

    func cancelSummaryStream(id: String) async {
        await summaryStreams.cancel(id: id)
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
        let nextRunner: ModelRunner
        if let resolvedURL {
            if runner == nil || modelURL != resolvedURL || self.maxTokens != tokens {
                os_log(
                    "Using MLX model at %{public}@ (maxTokens=%{public}d)",
                    log: log,
                    type: .info,
                    resolvedURL.path,
                    tokens
                )
                runner = ModelRouter(preferred: .mlx, modelURL: resolvedURL, maxTokens: tokens)
                modelURL = resolvedURL
                self.maxTokens = tokens
                orchestrator = nil
                summaryService = nil
            }
            nextRunner = runner ?? StaticModelRunner()
        } else {
            os_log("No model directory found; using static fallback", log: log, type: .info)
            let fallback = StaticModelRunner()
            runner = fallback
            modelURL = nil
            self.maxTokens = tokens
            orchestrator = nil
            summaryService = nil
            nextRunner = fallback
        }

        if orchestrator == nil {
            orchestrator = AgentOrchestrator(model: nextRunner)
        }
        if summaryService == nil {
            summaryService = SummaryService(model: nextRunner)
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

        if type == "summary.start" {
            guard let requestPayload = dict["request"] else {
                os_log("Missing summary request payload", log: log, type: .error)
                return ["ok": false, "error": "missing_request"]
            }
            do {
                guard JSONSerialization.isValidJSONObject(requestPayload) else {
                    os_log("Summary request payload is not valid JSON", log: log, type: .error)
                    return ["ok": false, "error": "invalid_request_payload"]
                }
                let data = try JSONSerialization.data(withJSONObject: requestPayload, options: [])
                let planRequest = try JSONDecoder().decode(PlanRequest.self, from: data)
                let maxTokens = (dict["maxTokens"] as? NSNumber)?.intValue
                var goalPlanHint: GoalPlan?
                if let hintPayload = dict["goalPlan"], JSONSerialization.isValidJSONObject(hintPayload) {
                    let hintData = try JSONSerialization.data(withJSONObject: hintPayload, options: [])
                    goalPlanHint = try? JSONDecoder().decode(GoalPlan.self, from: hintData)
                }
                let streamId = try await agent.startSummaryStream(
                    request: planRequest,
                    goalPlanHint: goalPlanHint,
                    maxTokens: maxTokens
                )
                return ["ok": true, "stream": ["id": streamId]]
            } catch {
                os_log("Summary start error: %{public}@", log: log, type: .error, error.localizedDescription)
                return ["ok": false, "error": error.localizedDescription]
            }
        }

        if type == "summary.poll" {
            guard let streamId = dict["streamId"] as? String, !streamId.isEmpty else {
                return ["ok": false, "error": "missing_stream_id"]
            }
            if let result = await agent.pollSummaryStream(id: streamId) {
                var payload: [String: Any] = [
                    "ok": true,
                    "streamId": streamId,
                    "chunks": result.chunks,
                    "done": result.done
                ]
                if let error = result.error {
                    payload["error"] = error
                }
                return payload
            }
            return ["ok": false, "error": "unknown_stream"]
        }

        if type == "summary.cancel" {
            if let streamId = dict["streamId"] as? String, !streamId.isEmpty {
                await agent.cancelSummaryStream(id: streamId)
            }
            return ["ok": true]
        }

        guard type == "plan" else {
            os_log("Unsupported native message type=%{public}@", log: log, type: .error, type)
            return ["ok": false, "error": "unsupported_type"]
        }

        guard let requestPayload = dict["request"] else {
            os_log("Missing request payload", log: log, type: .error)
            return ["ok": false, "error": "missing_request"]
        }

        do {
            guard JSONSerialization.isValidJSONObject(requestPayload) else {
                os_log("Plan request payload is not valid JSON", log: log, type: .error)
                return ["ok": false, "error": "invalid_request_payload"]
            }
            let data = try JSONSerialization.data(withJSONObject: requestPayload, options: [])
            let planRequest = try JSONDecoder().decode(PlanRequest.self, from: data)
            let maxTokens = (dict["maxTokens"] as? NSNumber)?.intValue
            let response = try await agent.plan(request: planRequest, maxTokens: maxTokens)
            let jsonData = try JSONEncoder().encode(response)
            let jsonObject = try JSONSerialization.jsonObject(with: jsonData, options: [])
            return ["ok": true, "plan": jsonObject]
        } catch let error as PlanValidationError {
            os_log("Plan validation error: %{public}@", log: log, type: .error, error.localizedDescription)
            return ["ok": false, "error": error.localizedDescription]
        } catch {
            os_log("Plan error: %{public}@", log: log, type: .error, error.localizedDescription)
            return ["ok": false, "error": error.localizedDescription]
        }
    }
}
