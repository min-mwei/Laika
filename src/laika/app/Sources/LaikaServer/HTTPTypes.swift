import Foundation

struct HTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

struct HTTPResponse {
    let statusCode: Int
    let headers: [String: String]
    let body: Data

    static func json(statusCode: Int, payload: [String: String]) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [])) ?? Data()
        return HTTPResponse(
            statusCode: statusCode,
            headers: [
                "Content-Type": "application/json",
                "Content-Length": String(data.count)
            ],
            body: data
        )
    }
}

enum HTTPStatus {
    static func reasonPhrase(for code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 500: return "Internal Server Error"
        default: return "HTTP"
        }
    }
}
