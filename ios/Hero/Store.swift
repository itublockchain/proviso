import Foundation
import SwiftUI

/// App-wide observable state. One store, kept small: it owns the API instance and cached data,
/// views read directly from it instead of duplicating fetch logic.
@Observable
@MainActor
final class Store {
    var demoMode: Bool {
        didSet {
            UserDefaults.standard.set(demoMode, forKey: "hero.demoMode")
            Task { await loadAll() } // switch data source right away
        }
    }
    var backendURLString: String {
        didSet {
            UserDefaults.standard.set(backendURLString, forKey: "hero.backendURL")
            if !demoMode { Task { await loadAll() } }
        }
    }

    var requests: [HeroRequest] = []
    var approvals: [Approval] = []
    var budgets: BudgetsResponse?
    var isLoading = false
    var errorMessage: String?
    var selectedTab = 0
    var showingComposer = false
    var approvalsPath: [String] = []

    private var mockAPI = MockAPI()
    /// Public tunnel to the demo backend, so the app works on a real phone too.
    static let defaultBackend = "https://uncookable-izaiah-dualistic.ngrok-free.dev"

    private var api: API {
        if demoMode {
            return mockAPI
        }
        let url = URL(string: backendURLString) ?? URL(string: Self.defaultBackend)!
        return LiveAPI(baseURL: url)
    }

    init() {
        self.demoMode = UserDefaults.standard.object(forKey: "hero.demoMode") as? Bool ?? true
        self.backendURLString = UserDefaults.standard.string(forKey: "hero.backendURL") ?? Self.defaultBackend
    }

    func loadAll() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            async let r = api.fetchRequests()
            async let a = api.fetchApprovals()
            async let b = api.fetchBudgets()
            requests = try await r
            approvals = try await a
            budgets = try await b
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func request(id: String) -> HeroRequest? {
        requests.first { $0.id == id }
    }

    func approval(id: String) -> Approval? {
        approvals.first { $0.orderId == id }
    }

    func sendChat(requestId: String?, message: String) async throws -> ChatReply {
        try await api.chat(requestId: requestId, message: message)
    }

    func submitDraft(_ draft: RequestDraft) async throws {
        let created = try await api.createRequest(draft)
        requests.insert(created, at: 0)
    }

    func updateBudget(name: String, limitUsd: Double, pct: Double?) async throws {
        let updated = try await api.updateBudget(name: name, limitUsd: limitUsd, pct: pct)
        if let idx = budgets?.categories.firstIndex(where: { $0.name == name }) {
            budgets?.categories[idx] = updated
        }
    }

    /// Only meaningful in demo mode: advances the mock approval through approved -> paid.
    func simulateApprovalCompletion(orderId: String) {
        Task {
            await mockAPI.simulateApprovalCompletion(orderId: orderId)
            await refreshApproval(orderId: orderId)
        }
    }

    /// hero://approval/<orderId> — World App's `return_to` lands here after the user approves.
    func handleDeepLink(_ url: URL) {
        guard url.scheme == "hero", url.host() == "approval", !url.lastPathComponent.isEmpty, url.lastPathComponent != "/" else { return }
        let orderId = url.lastPathComponent
        selectedTab = 1
        if approvalsPath.last != orderId { approvalsPath = [orderId] }
        Task { await refreshApproval(orderId: orderId) }
    }

    func refreshApproval(orderId: String) async {
        if let updated = try? await api.fetchApproval(id: orderId),
           let idx = approvals.firstIndex(where: { $0.orderId == orderId }) {
            approvals[idx] = updated
        }
    }
}
