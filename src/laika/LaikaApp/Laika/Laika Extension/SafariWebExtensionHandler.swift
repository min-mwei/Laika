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

private actor NativeAgent {
    private var modelURL: URL?
    private var runner: ModelRunner?
    private var orchestrator: AgentOrchestrator?

    func plan(request: PlanRequest, maxTokens: Int?) async throws -> AgentResponse {
        try request.validate()
        os_log(
            "Plan request origin=%{public}@ mode=%{public}@ textChars=%{public}d elements=%{public}d",
            log: log,
            type: .info,
            request.context.origin,
            String(describing: request.context.mode),
            request.context.observation.text.count,
            request.context.observation.elements.count
        )
        let resolvedURL = resolveModelURL()
        let nextRunner: ModelRunner
        if let resolvedURL {
            if runner == nil || modelURL != resolvedURL {
                let tokens = maxTokens ?? 256
                os_log(
                    "Using MLX model at %{public}@ (maxTokens=%{public}d)",
                    log: log,
                    type: .info,
                    resolvedURL.path,
                    tokens
                )
                runner = ModelRouter(preferred: .mlx, modelURL: resolvedURL, maxTokens: tokens)
                modelURL = resolvedURL
                orchestrator = AgentOrchestrator(model: runner ?? StaticModelRunner())
            }
            nextRunner = runner ?? StaticModelRunner()
        } else {
            os_log("No model directory found; using static fallback", log: log, type: .info)
            nextRunner = StaticModelRunner()
            orchestrator = AgentOrchestrator(model: nextRunner)
        }

        if orchestrator == nil {
            orchestrator = AgentOrchestrator(model: nextRunner)
        }
        let response = try await orchestrator!.runOnce(context: request.context, userGoal: request.goal)
        os_log("Plan response actions=%{public}d", log: log, type: .info, response.actions.count)
        return response
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
    private let agent = NativeAgent()

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

        do {
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
