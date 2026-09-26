import Foundation

protocol API: Sendable {
    func chat(requestId: String?, message: String) async throws -> ChatReply
    func createRequest(_ draft: RequestDraft) async throws -> ProvisoRequest
    func fetchRequests() async throws -> [ProvisoRequest]
    func fetchRequest(id: String) async throws -> ProvisoRequest
    func fetchApprovals() async throws -> [Approval]
    func fetchApproval(id: String) async throws -> Approval
    func fetchBudgets() async throws -> BudgetsResponse
    func updateBudget(name: String, limitUsd: Double, pct: Double?) async throws -> Category
    func linkWorldID() async throws -> WorldLink
    func fetchWorldLinkStatus(id: String) async throws -> WorldLinkStatusResponse
    func me() async throws -> Me
    func logout() async throws
    func startWallet(handle: String?) async throws -> WalletStart
    func useDemoWallet() async throws
    func demo(requestId: String, scenario: DemoScenario) async throws -> ProvisoRequest
    /// POST api/dev/reset — hackathon-only: wipes the signed-in account (chain + backend rows),
    /// frees their ENS name; the session is invalid immediately after this returns.
    func resetEverything() async throws -> ResetResult
}

enum APIError: Error, LocalizedError {
    case badResponse
    case decoding(Error)
    case sessionExpired
    /// PUT api/budgets/{name} on a wallet account: only the user's own wallet can change limits.
    case walletRequired
    /// Any other `{"error": "..."}` body from a non-2xx response, shown to the user as-is.
    case server(String)
    /// api/dev/reset returned 404/403 (older backend, or disabled) — caller falls back to a
    /// local-only reset.
    case resetUnavailable

    var errorDescription: String? {
        switch self {
        case .badResponse: return "The server returned an unexpected response."
        case .decoding(let e): return "Failed to decode response: \(e.localizedDescription)"
        case .sessionExpired: return "Your session expired. Sign in again."
        case .walletRequired: return "Only your wallet can change this"
        case .server(let message): return message
        case .resetUnavailable: return "Server reset unavailable"
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

    /// A 401 with `{"error":"sign_in_required"}` means the session is gone — the caller signs out.
    /// A 409 with `{"error":"wallet_required"}` (PUT budgets on a wallet account) maps to a
    /// friendly message; any other `{"error": "..."}` body is surfaced as-is (e.g. wallet/start
    /// handle validation); anything else is a generic failure.
    private static func validate(_ response: URLResponse, _ data: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw APIError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            let body = try? JSONDecoder().decode([String: String].self, from: data)
            if http.statusCode == 401, body?["error"] == "sign_in_required" { throw APIError.sessionExpired }
            if http.statusCode == 409, body?["error"] == "wallet_required" { throw APIError.walletRequired }
            if let message = body?["message"] ?? body?["error"] { throw APIError.server(message) } // a readable message when the backend sends one
            throw APIError.badResponse
        }
    }

    private struct ChatBody: Encodable { var requestId: String?; var message: String }
    private struct BudgetBody: Encodable { var limitUsd: Double; var pct: Double? }

    func chat(requestId: String?, message: String) async throws -> ChatReply {
        try await send("POST", "api/chat", body: ChatBody(requestId: requestId, message: message))
    }

    func createRequest(_ draft: RequestDraft) async throws -> ProvisoRequest {
        try await send("POST", "api/requests", body: draft)
    }

    func fetchRequests() async throws -> [ProvisoRequest] {
        try await get("api/requests")
    }

    func fetchRequest(id: String) async throws -> ProvisoRequest {
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

    private struct WalletStartBody: Encodable { var handle: String? }
    func startWallet(handle: String?) async throws -> WalletStart {
        try await send("POST", "api/wallet/start", body: WalletStartBody(handle: handle))
    }

    func useDemoWallet() async throws {
        let _: OkResponse = try await send("POST", "api/wallet/demo", body: EmptyBody())
    }

    private struct DemoBody: Encodable { var scenario: DemoScenario }
    func demo(requestId: String, scenario: DemoScenario) async throws -> ProvisoRequest {
        try await send("POST", "api/requests/\(requestId)/demo", body: DemoBody(scenario: scenario))
    }

    private struct ResetResponse: Decodable { var ok: Bool; var reset: ResetResult }
    func resetEverything() async throws -> ResetResult {
        let request = authorizedRequest(baseURL.appendingPathComponent("api/dev/reset"), method: "POST")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw APIError.badResponse }
        if http.statusCode == 404 || http.statusCode == 403 { throw APIError.resetUnavailable }
        try Self.validate(response, data)
        return try decoder.decode(ResetResponse.self, from: data).reset
    }
}
