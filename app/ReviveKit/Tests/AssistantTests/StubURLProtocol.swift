import Foundation

/// Answers requests without the network. Each test registers a handler under its own host (a
/// fresh UUID), so tests running in parallel never see each other's requests.
final class StubURLProtocol: URLProtocol {
    /// Status and body for a request; the request body is passed separately because URLSession
    /// hands it to protocols as a stream.
    typealias Handler = @Sendable (URLRequest, Data) -> (status: Int, body: Data)

    private static let registry = Registry()

    /// A session whose requests all go to this stub.
    static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    /// Registers `handler` for a new host and returns a base URL on it.
    static func register(_ handler: @escaping Handler) -> String {
        let host = "\(UUID().uuidString.lowercased()).stub.test"
        registry.set(handler, for: host)
        return "https://\(host)/v1"
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host, let handler = Self.registry.handler(for: host) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        let (status, body) = handler(request, Self.body(of: request))
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    private static func body(of request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let n = stream.read(&buffer, maxLength: buffer.count)
            if n <= 0 { break }
            data.append(buffer, count: n)
        }
        return data
    }

    private final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var handlers: [String: Handler] = [:]

        func set(_ handler: @escaping Handler, for host: String) {
            lock.lock()
            defer { lock.unlock() }
            handlers[host] = handler
        }

        func handler(for host: String) -> Handler? {
            lock.lock()
            defer { lock.unlock() }
            return handlers[host]
        }
    }
}

/// Requests a stub received, in order, readable from the test.
final class RequestLog: @unchecked Sendable {
    struct Entry {
        let request: URLRequest
        let body: Data

        /// The JSON body as a dictionary.
        var json: [String: Any] {
            (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        }
    }

    private let lock = NSLock()
    private var stored: [Entry] = []

    func append(_ request: URLRequest, _ body: Data) {
        lock.lock()
        defer { lock.unlock() }
        stored.append(Entry(request: request, body: body))
    }

    var entries: [Entry] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

/// A `/chat/completions` reply whose message content is `content`.
func chatReply(_ content: String) -> Data {
    let object: [String: Any] = ["choices": [["index": 0, "message": ["role": "assistant", "content": content]]]]
    return (try? JSONSerialization.data(withJSONObject: object)) ?? Data()
}
