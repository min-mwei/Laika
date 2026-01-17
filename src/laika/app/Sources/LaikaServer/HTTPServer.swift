import Foundation
import Network

final class HTTPServer {
    private let port: NWEndpoint.Port
    private let handler: (HTTPRequest) async -> HTTPResponse
    private var listener: NWListener?
    private var connections: [UUID: HTTPConnection] = [:]

    init(port: UInt16, handler: @escaping (HTTPRequest) async -> HTTPResponse) throws {
        guard let port = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "LaikaHTTPServer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Invalid port"])
        }
        self.port = port
        self.handler = handler
    }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: port)
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            let id = UUID()
            let httpConnection = HTTPConnection(connection: connection, handler: self.handler) { [weak self] in
                self?.connections[id] = nil
            }
            self.connections[id] = httpConnection
            httpConnection.start()
        }
        listener.start(queue: .global())
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }
}

private final class HTTPConnection {
    private let connection: NWConnection
    private let handler: (HTTPRequest) async -> HTTPResponse
    private let onClose: () -> Void
    private var buffer = Data()
    private var expectedBodyLength: Int?

    init(
        connection: NWConnection,
        handler: @escaping (HTTPRequest) async -> HTTPResponse,
        onClose: @escaping () -> Void
    ) {
        self.connection = connection
        self.handler = handler
        self.onClose = onClose
    }

    func start() {
        connection.start(queue: .global())
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, error in
            guard let self else { return }
            if let error {
                print("Connection receive error: \(error)")
                self.connection.cancel()
                self.onClose()
                return
            }
            if let data {
                buffer.append(data)
                if let request = parseRequest() {
                    Task { [weak self] in
                        guard let self else { return }
                        let response = await self.handler(request)
                        self.send(response: response)
                    }
                    return
                }
            }
            receive()
        }
    }

    private func parseRequest() -> HTTPRequest? {
        guard let headerRange = buffer.range(of: Data([13, 10, 13, 10])) else {
            return nil
        }
        let headerData = buffer.subdata(in: buffer.startIndex..<headerRange.lowerBound)
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            return nil
        }
        let lines = headerString.split(separator: "\r\n")
        guard let requestLine = lines.first else {
            return nil
        }
        let parts = requestLine.split(separator: " ")
        guard parts.count >= 2 else {
            return nil
        }
        let method = String(parts[0])
        let path = String(parts[1])
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let components = line.split(separator: ":", maxSplits: 1)
            if components.count == 2 {
                let key = components[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                let value = components[1].trimmingCharacters(in: .whitespacesAndNewlines)
                headers[key] = value
            }
        }
        if expectedBodyLength == nil {
            expectedBodyLength = Int(headers["content-length"] ?? "0")
        }
        let headerEndIndex = headerRange.upperBound
        let bodyLength = expectedBodyLength ?? 0
        if buffer.count < headerEndIndex + bodyLength {
            return nil
        }
        let bodyData = buffer.subdata(in: headerEndIndex..<(headerEndIndex + bodyLength))
        buffer.removeAll()
        expectedBodyLength = nil
        return HTTPRequest(method: method, path: path, headers: headers, body: bodyData)
    }

    private func send(response: HTTPResponse) {
        var headers = response.headers
        headers["Connection"] = "close"
        let statusLine = "HTTP/1.1 \(response.statusCode) \(HTTPStatus.reasonPhrase(for: response.statusCode))\r\n"
        let headerLines = headers.map { "\($0.key): \($0.value)\r\n" }.joined()
        let responseData = Data(statusLine.utf8) + Data(headerLines.utf8) + Data("\r\n".utf8) + response.body
        connection.send(content: responseData, completion: .contentProcessed { _ in
            self.connection.cancel()
            self.onClose()
        })
    }
}
