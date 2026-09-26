import Foundation

protocol API: Sendable {
    func chat(requestId: String?, message: String) async throws -> ChatReply
    func createRequest(_ draft: RequestDraft) async throws -> HeroRequest
    func fetchRequests() async throws -> [HeroRequest]
    func fetchRequest(id: String) async throws -> HeroRequest
    func fetchApprovals() async throws -> [Approval]
    func fetchApproval(id: String) async throws -> Approval
    func fetchBudgets() async throws -> BudgetsResponse
    func updateBudget(name: String, limitUsd: Double, pct: Double?) async throws -> Category
    func linkWorldID() async throws -> WorldLink
    func fetchWorldLinkStatus(id: String) async throws -> WorldLinkStatusResponse
    func me() async throws -> Me
    func logout() async throws
}

enum APIError: Error, LocalizedError {
    case badResponse
    case decoding(Error)
    case sessionExpired

    var errorDescription: String? {
        switch self {
        case .badResponse: return "The server returned an unexpected response."
        case .decoding(let e): return "Failed to decode response: \(e.localizedDescription)"
        case .sessionExpired: return "Your session expired. Sign in again."
        }
    }
}

/// Talks to the Node backend described in the contract. Used when Demo Mode is off.
final class LiveAPI: API {
    let baseURL: URL
    private let session: URLSession
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    init(baseURL: URL) {
        self.baseURL = baseURL
        self.session = .shared
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
    }

    private func authorizedRequest(_ url: URL, method: String? = nil) -> URLRequest {
        var request = URLRequest(url: url)
        if let method { request.httpMethod = method }
        if let token = Keychain.token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    private func get<T: Decodable>(_ path: String) async throws -> T {
        let (data, response) = try await session.data(for: authorizedRequest(baseURL.appendingPathComponent(path)))
        try Self.validate(response, data)
        return try decoder.decode(T.self, from: data)
    }

    private func send<Body: Encodable, T: Decodable>(_ method: String, _ path: String, body: Body) async throws -> T {
        var request = authorizedRequest(baseURL.appendingPathComponent(path), method: method)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        let (data, response) = try await session.data(for: request)
        try Self.validate(response, data)
        return try decoder.decode(T.self, from: data)
    }

    /// A 401 with `{"error":"sign_in_required"}` means the session is gone — the caller signs out; anything else is a generic failure.
    private static func validate(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw APIError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401,
               let body = try? JSONDecoder().decode([String: String].self, from: data),
               body["error"] == "sign_in_required" {
                throw APIError.sessionExpired
            }
            throw APIError.badResponse
        }
    }

    private struct ChatBody: Encodable { var requestId: String?; var message: String }
    private struct BudgetBody: Encodable { var limitUsd: Double; var pct: Double? }

    func chat(requestId: String?, message: String) async throws -> ChatReply {
        try await send("POST", "api/chat", body: ChatBody(requestId: requestId, message: message))
    }

    func createRequest(_ draft: RequestDraft) async throws -> HeroRequest {
        try await send("POST", "api/requests", body: draft)
    }

    func fetchRequests() async throws -> [HeroRequest] {
        try await get("api/requests")
    }

    func fetchRequest(id: String) async throws -> HeroRequest {
        try await get("api/requests/\(id)")
    }

    func fetchApprovals() async throws -> [Approval] {
        try await get("api/approvals")
    }

    func fetchApproval(id: String) async throws -> Approval {
        try await get("api/approvals/\(id)")
    }

    func fetchBudgets() async throws -> BudgetsResponse {
        try await get("api/budgets")
    }

    func updateBudget(name: String, limitUsd: Double, pct: Double?) async throws -> Category {
        try await send("PUT", "api/budgets/\(name)", body: BudgetBody(limitUsd: limitUsd, pct: pct))
    }

    private struct EmptyBody: Encodable {}

    func linkWorldID() async throws -> WorldLink {
        try await send("POST", "api/world/link", body: EmptyBody())
    }

    func fetchWorldLinkStatus(id: String) async throws -> WorldLinkStatusResponse {
        try await get("api/world/link/\(id)")
    }

    func me() async throws -> Me {
        try await get("api/me")
    }

    private struct OkResponse: Decodable { var ok: Bool }
    func logout() async throws {
        let _: OkResponse = try await send("POST", "api/logout", body: EmptyBody())
    }
}
