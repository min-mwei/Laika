import Foundation
import LaikaShared

struct SummaryStreamPollResult: Sendable {
    let chunks: [String]
    let done: Bool
    let error: String?
}

struct SummaryStreamMetadata: Sendable {
    let runId: String?
    let step: Int?
    let maxSteps: Int?
    let goalPlan: GoalPlan
    let mode: SiteMode
    let origin: String
    let url: String
    let title: String
}

actor SummaryStreamManager {
    private struct StreamState {
        var queue: [String]
        var buffer: String
        var fullText: String
        var done: Bool
        var error: String?
        var task: Task<Void, Never>?
        var lastUpdated: Date
        var metadata: SummaryStreamMetadata?
    }

    private var streams: [String: StreamState] = [:]

    func start(id: String, stream: AsyncThrowingStream<String, Error>, metadata: SummaryStreamMetadata?) {
        let task = Task {
            do {
                for try await chunk in stream {
                    await appendChunk(id: id, chunk: chunk)
                }
                await finish(id: id, error: nil)
            } catch {
                await finish(id: id, error: error.localizedDescription)
            }
        }
        streams[id] = StreamState(
            queue: [],
            buffer: "",
            fullText: "",
            done: false,
            error: nil,
            task: task,
            lastUpdated: Date(),
            metadata: metadata
        )
    }

    func poll(id: String, maxChunks: Int) -> SummaryStreamPollResult? {
        guard var state = streams[id] else {
            return nil
        }
        let count = min(maxChunks, state.queue.count)
        let chunks = count > 0 ? Array(state.queue.prefix(count)) : []
        if count > 0 {
            state.queue.removeFirst(count)
        }
        state.lastUpdated = Date()
        let done = state.done && state.queue.isEmpty && state.buffer.isEmpty
        let error = state.error
        if done {
            streams.removeValue(forKey: id)
        } else {
            streams[id] = state
        }
        return SummaryStreamPollResult(chunks: chunks, done: done, error: error)
    }

    func cancel(id: String) {
        guard let state = streams[id] else {
            return
        }
        state.task?.cancel()
        streams.removeValue(forKey: id)
    }

    private func appendChunk(id: String, chunk: String) {
        guard var state = streams[id] else {
            return
        }
        state.buffer += chunk
        state.fullText += chunk
        if shouldFlush(buffer: state.buffer) {
            state.queue.append(state.buffer)
            state.buffer = ""
        }
        state.lastUpdated = Date()
        streams[id] = state
    }

    private func finish(id: String, error: String?) {
        guard var state = streams[id] else {
            return
        }
        if !state.buffer.isEmpty {
            state.queue.append(state.buffer)
            state.buffer = ""
        }
        state.done = true
        state.error = error
        state.lastUpdated = Date()
        streams[id] = state
        logCompletion(state: state)
    }

    private func shouldFlush(buffer: String) -> Bool {
        if buffer.count >= 48 {
            return true
        }
        if buffer.contains("\n") {
            return true
        }
        return false
    }

    private func logCompletion(state: StreamState) {
        guard let metadata = state.metadata else {
            return
        }
        let trimmed = state.fullText.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = trimmed.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).count
        var payload: [String: JSONValue] = [
            "summaryPreview": .string(LaikaLogger.preview(trimmed, maxChars: 360)),
            "summaryChars": .number(Double(trimmed.count)),
            "summaryWords": .number(Double(words)),
            "intent": .string(metadata.goalPlan.intent.rawValue),
            "wantsComments": .bool(metadata.goalPlan.wantsComments),
            "mode": .string(metadata.mode.rawValue),
            "origin": .string(metadata.origin),
            "pageURL": .string(metadata.url),
            "pageTitlePreview": .string(LaikaLogger.preview(metadata.title, maxChars: 200)),
            "source": .string("summary_stream")
        ]
        if let error = state.error, !error.isEmpty {
            payload["error"] = .string(error)
        }
        LaikaLogger.logAgentEvent(
            type: "agent.summary_stream",
            runId: metadata.runId,
            step: metadata.step,
            maxSteps: metadata.maxSteps,
            payload: payload
        )
        LaikaLogger.logAgentEvent(
            type: "agent.final_summary",
            runId: metadata.runId,
            step: metadata.step,
            maxSteps: metadata.maxSteps,
            payload: payload
        )
    }
}
