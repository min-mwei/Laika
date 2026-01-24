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
    private var maxTokens: Int?

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
            }
            nextRunner = runner ?? StaticModelRunner()
        } else {
            os_log("No model directory found; using static fallback", log: log, type: .info)
            let fallback = StaticModelRunner()
            runner = fallback
            modelURL = nil
            self.maxTokens = tokens
            orchestrator = nil
            nextRunner = fallback
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
}
