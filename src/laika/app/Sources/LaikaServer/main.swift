import Foundation
import LaikaAgentCore
import LaikaModel
import LaikaShared

struct ServerConfig {
    let port: UInt16
    let modelURL: URL?
    let maxTokens: Int
    let useStatic: Bool
}

func parseArgs() -> ServerConfig {
    var port: UInt16 = 8765
    var modelURL: URL?
    var maxTokens = 2048
    var useStatic = false

    var iterator = CommandLine.arguments.makeIterator()
    _ = iterator.next()
    while let arg = iterator.next() {
        switch arg {
        case "--port":
            if let value = iterator.next(), let parsed = UInt16(value) {
                port = parsed
            }
        case "--model-dir":
            if let value = iterator.next() {
                modelURL = URL(fileURLWithPath: value)
            }
        case "--max-tokens":
            if let value = iterator.next(), let parsed = Int(value) {
                maxTokens = parsed
            }
        case "--static":
            useStatic = true
        default:
            continue
        }
    }

    if modelURL == nil, let envValue = ProcessInfo.processInfo.environment["LAIKA_MODEL_DIR"] {
        modelURL = URL(fileURLWithPath: envValue)
    }

    return ServerConfig(port: port, modelURL: modelURL, maxTokens: maxTokens, useStatic: useStatic)
}

func usage() {
    let message = """
Usage: laika-server [--port 8765] [--model-dir /path/to/MLX-model] [--max-tokens 2048] [--static]
Environment:
  LAIKA_MODEL_DIR   Path to MLX model directory
"""
    print(message)
}

func corsHeaders() -> [String: String] {
    [
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
        "Access-Control-Allow-Headers": "Content-Type"
    ]
}

func handleRequest(_ request: HTTPRequest, planService: PlanService) async -> HTTPResponse {
    if request.method == "OPTIONS" {
        return HTTPResponse(statusCode: 204, headers: corsHeaders(), body: Data())
    }

    if request.method == "GET", request.path == "/health" {
        var headers = corsHeaders()
        let data = try? JSONSerialization.data(withJSONObject: ["status": "ok"], options: [])
        headers["Content-Type"] = "application/json"
        headers["Content-Length"] = String(data?.count ?? 0)
        return HTTPResponse(statusCode: 200, headers: headers, body: data ?? Data())
    }

    guard request.method == "POST", request.path == "/plan" else {
        var headers = corsHeaders()
        headers["Content-Type"] = "application/json"
        let response = HTTPResponse.json(statusCode: 404, payload: ["error": "not_found"])
        return HTTPResponse(statusCode: response.statusCode, headers: headers.merging(response.headers) { $1 }, body: response.body)
    }

    do {
        let decoder = JSONDecoder()
        let planRequest = try decoder.decode(PlanRequest.self, from: request.body)
        let plan = try await planService.plan(from: planRequest)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(plan)
        var headers = corsHeaders()
        headers["Content-Type"] = "application/json"
        headers["Content-Length"] = String(data.count)
        return HTTPResponse(statusCode: 200, headers: headers, body: data)
    } catch let error as PlanValidationError {
        var headers = corsHeaders()
        headers["Content-Type"] = "application/json"
        let response = HTTPResponse.json(statusCode: 400, payload: ["error": error.localizedDescription])
        return HTTPResponse(statusCode: response.statusCode, headers: headers.merging(response.headers) { $1 }, body: response.body)
    } catch {
        var headers = corsHeaders()
        headers["Content-Type"] = "application/json"
        let response = HTTPResponse.json(statusCode: 500, payload: ["error": error.localizedDescription])
        return HTTPResponse(statusCode: response.statusCode, headers: headers.merging(response.headers) { $1 }, body: response.body)
    }
}

let config = parseArgs()
if config.useStatic == false && config.modelURL == nil {
    print("No model directory configured. Use --model-dir or LAIKA_MODEL_DIR, or pass --static.")
}

let runner: ModelRunner
if config.useStatic {
    runner = StaticModelRunner()
} else if let modelURL = config.modelURL {
    runner = ModelRouter(preferred: .mlx, modelURL: modelURL, maxTokens: config.maxTokens)
} else {
    runner = StaticModelRunner()
}

let planService = PlanService(modelRunner: runner)
let server = try HTTPServer(port: config.port) { request in
    await handleRequest(request, planService: planService)
}
try server.start()
print("Laika server listening on http://127.0.0.1:\(config.port)")
dispatchMain()
