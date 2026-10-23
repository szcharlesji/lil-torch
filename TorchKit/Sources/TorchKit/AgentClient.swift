import Foundation

public enum AgentError: LocalizedError, Sendable {
    case unauthorized
    case loginRequired(String?)
    case server(status: Int, message: String)
    case unreachable(String)

    public var errorDescription: String? {
        switch self {
        case .unauthorized:
            "The agent rejected this app's token. Pair it again."
        case .loginRequired:
            "Torch login needed."
        case .server(_, let message):
            message
        case .unreachable(let detail):
            "Can't reach the agent: \(detail)"
        }
    }
}

/// Talks to one lil-torch agent over HTTP (inside Tailscale).
public struct AgentClient: Sendable {
    public let baseURL: URL
    private let token: String
    private let session: URLSession

    public init(baseURL: URL, token: String, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.token = token
        self.session = session
    }

    public func info() async throws -> AgentInfo {
        try await get("/v1/info")
    }

    public func jobs(refresh: Bool = false) async throws -> JobSnapshot {
        try await get("/v1/torch/jobs", query: refresh ? ["refresh": "1"] : [:], timeout: 120)
    }

    public func log(path: String, lines: Int) async throws -> LogTail {
        try await get("/v1/torch/log", query: ["path": path, "lines": String(lines)], timeout: 60)
    }

    public func cancel(jobID: String) async throws {
        let _: Acknowledgement = try await send("POST", "/v1/torch/jobs/\(jobID)/cancel")
    }

    public func gpus(refresh: Bool = false) async throws -> GPUSnapshot {
        try await get("/v1/gpus", query: refresh ? ["refresh": "1"] : [:], timeout: 60)
    }

    public func events(since seq: Int) async throws -> EventPage {
        try await get("/v1/events", query: ["since": String(seq)])
    }

    /// Lets the agent push to this device through APNs.
    public func registerDevice(token deviceToken: String, sandbox: Bool, name: String, prefs: NotificationPrefs) async throws -> Bool {
        let body: [String: Any] = ["token": deviceToken, "environment": sandbox ? "sandbox" : "production",
                                   "name": name, "prefs": prefs.agentPrefs]
        let reply: Acknowledgement = try await send("POST", "/v1/devices", body: body)
        return reply.push ?? false
    }

    public func unregisterDevice(token deviceToken: String) async throws {
        let _: Acknowledgement = try await send("DELETE", "/v1/devices/\(deviceToken)")
    }

    public func testPush() async throws {
        let _: Acknowledgement = try await send("POST", "/v1/test-push")
    }

    /// A terminal on the agent's machine: `torch` (an SSH session that can log in
    /// to Torch) or `local` (a shell on the lab machine). Binary messages carry
    /// terminal bytes; text messages carry `{"type":"resize","cols":…,"rows":…}`.
    public func terminal(target: String, cols: Int, rows: Int) -> URLSessionWebSocketTask {
        var components = URLComponents(url: baseURL.appending(path: "/v1/terminal"), resolvingAgainstBaseURL: false)!
        components.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        components.queryItems = [
            URLQueryItem(name: "target", value: target),
            URLQueryItem(name: "cols", value: String(cols)),
            URLQueryItem(name: "rows", value: String(rows)),
        ]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return session.webSocketTask(with: request)
    }

    // MARK: - Plumbing

    private struct Acknowledgement: Decodable {
        var ok: Bool?
        var push: Bool?
    }

    private struct ErrorBody: Decodable {
        var error: String
    }

    public static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    private func get<T: Decodable>(_ path: String, query: [String: String] = [:], timeout: TimeInterval = 30) async throws -> T {
        try await send("GET", path, query: query, timeout: timeout)
    }

    private func send<T: Decodable>(
        _ method: String, _ path: String, query: [String: String] = [:], body: [String: Any]? = nil,
        timeout: TimeInterval = 30
    ) async throws -> T {
        var components = URLComponents(url: baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var request = URLRequest(url: components.url!, timeoutInterval: timeout)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code != .cancelled {
            throw AgentError.unreachable(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let message = (try? Self.decoder.decode(ErrorBody.self, from: data))?.error
        switch status {
        case 200..<300:
            return try Self.decoder.decode(T.self, from: data)
        case 401:
            throw AgentError.unauthorized
        case 409:
            throw AgentError.loginRequired(message)
        default:
            throw AgentError.server(status: status, message: message ?? HTTPURLResponse.localizedString(forStatusCode: status))
        }
    }
}

/// `liltorch://add?url=http://host:8765&token=…&name=…`, printed by the installer.
public struct PairingLink: Hashable, Identifiable, Sendable {
    public var url: URL
    public var token: String
    public var name: String

    public var id: String { url.absoluteString }

    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed), components.scheme == "liltorch",
              components.host == "add" else { return nil }
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        guard let urlText = items["url"], let url = URL(string: urlText), url.scheme?.hasPrefix("http") == true,
              let token = items["token"], !token.isEmpty else { return nil }
        self.url = url
        self.token = token
        self.name = items["name"].flatMap { $0.isEmpty ? nil : $0 } ?? url.host() ?? "Agent"
    }
}
