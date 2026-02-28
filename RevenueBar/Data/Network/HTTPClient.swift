import Foundation

struct HTTPResponse {
    let data: Data
    let response: HTTPURLResponse
}

enum HTTPClientError: LocalizedError {
    case nonHTTPResponse
    case invalidStatus(Int, Data)

    var errorDescription: String? {
        switch self {
        case .nonHTTPResponse:
            return "Response was not HTTP."
        case .invalidStatus(let code, _):
            return "Request failed with status code \(code)."
        }
    }
}

final class HTTPClient {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func send(_ request: URLRequest, retries: Int = 2) async throws -> HTTPResponse {
        var lastError: Error?

        for attempt in 0...retries {
            do {
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw HTTPClientError.nonHTTPResponse
                }

                if (200..<300).contains(http.statusCode) {
                    return HTTPResponse(data: data, response: http)
                }

                if http.statusCode == 401 || http.statusCode == 403 {
                    throw ProviderAdapterError.unauthorized
                }

                if shouldRetry(statusCode: http.statusCode), attempt < retries {
                    try await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt)) * 300_000_000))
                    continue
                }

                throw HTTPClientError.invalidStatus(http.statusCode, data)
            } catch {
                lastError = error
                if attempt < retries {
                    try await Task.sleep(nanoseconds: UInt64(pow(2.0, Double(attempt)) * 300_000_000))
                    continue
                }
            }
        }

        throw lastError ?? URLError(.unknown)
    }

    func sendJSON(_ request: URLRequest, retries: Int = 2) async throws -> Any {
        let response = try await send(request, retries: retries)
        return try JSONSerialization.jsonObject(with: response.data)
    }

    private func shouldRetry(statusCode: Int) -> Bool {
        statusCode == 429 || (500...599).contains(statusCode)
    }
}

extension URLRequest {
    mutating func setBearerToken(_ token: String) {
        setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }

    mutating func setBasicAuth(username: String, password: String = "") {
        let credentials = "\(username):\(password)"
        let encoded = Data(credentials.utf8).base64EncodedString()
        setValue("Basic \(encoded)", forHTTPHeaderField: "Authorization")
    }
}
