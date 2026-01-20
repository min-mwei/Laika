import Foundation
import LaikaAgentCore
import LaikaModel
import LaikaShared

struct CLIArgs {
    let goal: String
    let origin: String
    let modelURL: URL?
    let useStatic: Bool
    let maxTokens: Int
}

func parseArgs() -> CLIArgs? {
    var goal: String?
    var origin: String = "https://example.com"
    var modelURL: URL?
    var useStatic = false
    var maxTokens = 2048

    var iterator = CommandLine.arguments.makeIterator()
    _ = iterator.next()
    while let arg = iterator.next() {
        switch arg {
        case "--goal":
            goal = iterator.next()
        case "--origin":
            if let value = iterator.next() {
                origin = value
            }
        case "--model-dir":
            if let value = iterator.next() {
                modelURL = URL(fileURLWithPath: value)
            }
        case "--static":
            useStatic = true
        case "--max-tokens":
            if let value = iterator.next(), let parsed = Int(value) {
                maxTokens = parsed
            }
        default:
            continue
        }
    }

    guard let goalValue = goal else {
        return nil
    }
    return CLIArgs(
        goal: goalValue,
        origin: origin,
        modelURL: modelURL,
        useStatic: useStatic,
        maxTokens: maxTokens
    )
}

func usage() {
    let message = """
Usage: laika-agent --goal "..." [--origin https://example.com] [--model-dir /path] [--max-tokens 2048] [--static]
"""
    print(message)
}

@main
struct LaikaAgentCLI {
    static func main() async {
        guard let args = parseArgs() else {
            usage()
            return
        }

        let element = ObservedElement(
            handleId: "el-1",
            role: "button",
            label: "Continue",
            boundingBox: BoundingBox(x: 0, y: 0, width: 10, height: 10)
        )
        let observation = Observation(
            url: args.origin,
            title: "Sample",
            text: "",
            elements: [element]
        )
        let context = ContextPack(
            origin: args.origin,
            mode: .assist,
            observation: observation,
            recentToolCalls: []
        )

        let model: ModelRunner
        if args.useStatic {
            model = StaticModelRunner()
        } else {
            model = ModelRouter(preferred: .mlx, modelURL: args.modelURL, maxTokens: args.maxTokens)
        }
        let orchestrator = AgentOrchestrator(model: model)

        do {
            let response = try await orchestrator.runOnce(context: context, userGoal: args.goal)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(response)
            if let json = String(data: data, encoding: .utf8) {
                print(json)
            }
        } catch {
            fputs("Error: \(error)\n", stderr)
        }
    }
}
