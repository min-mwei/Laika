import Foundation

public struct RunEvent: Codable, Equatable, Sendable {
    public let timestamp: Date
    public let type: String
    public let payload: JSONValue

    public init(timestamp: Date = Date(), type: String, payload: JSONValue) {
        self.timestamp = timestamp
        self.type = type
        self.payload = payload
    }
}

public struct RunLog {
    private let fileURL: URL
    private let encoder: JSONEncoder

    public init(fileURL: URL) {
        self.fileURL = fileURL
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
    }

    public func append(_ event: RunEvent) throws {
        let data = try encoder.encode(event)
        guard var line = String(data: data, encoding: .utf8) else {
            throw NSError(domain: "LaikaRunLog", code: 1, userInfo: [NSLocalizedDescriptionKey: "UTF-8 encoding failed"])
        }
        line.append("\n")
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let handle = try FileHandle(forWritingTo: fileURL)
            try handle.seekToEnd()
            if let lineData = line.data(using: .utf8) {
                try handle.write(contentsOf: lineData)
            }
            try handle.close()
        } else {
            try line.write(to: fileURL, atomically: true, encoding: .utf8)
        }
    }
}
