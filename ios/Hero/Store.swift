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
            Task { await loadSession() } // switch data source right away
        }
    }
    var backendURLString: String {
        didSet {
            UserDefaults.standard.set(backendURLString, forKey: "hero.backendURL")
            if !demoMode { Task { await loadSession() } }
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

    /// Mandatory Sign in with World ID: `nil` while the session is still being checked at launch.
    var me: Me?
    var onboardingSeen: Bool {
        didSet { UserDefaults.standard.set(onboardingSeen, forKey: "hero.onboardingSeen") }
    }

    enum AuthPhase { case loading, signedOut, signedIn }
    var authPhase: AuthPhase {
        guard let me else { return .loading }
        return me.signedIn ? .signedIn : .signedOut
    }
    var isSignedIn: Bool { me?.signedIn == true }

    private var mockAPI = MockAPI()
    /// Public tunnel to the demo backend, so the app works on a real phone too.
    static let defaultBackend = "https://uncookable-izaiah-dualistic.ngrok-free.dev"
    private static let demoSignedInKey = "hero.demoSignedIn"

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
        self.onboardingSeen = UserDefaults.standard.bool(forKey: "hero.onboardingSeen")
    }

    /// Runs an API call, and on a 401 sign-out-required response drops the local session so the
    /// UI falls back to sign-in — the one place that needs to know about that error shape.
    private func run<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch APIError.sessionExpired {
            clearSessionLocally()
            throw APIError.sessionExpired
        }
    }

    private func clearSessionLocally() {
        Keychain.token = nil
        me = .signedOut
    }

    /// Checks the current session (real backend token, or the demo mock) and loads app data if signed in.
    /// Called once at launch, and again right after sign-in/sign-out/demo-mode changes.
    func loadSession() async {
        if demoMode {
            if UserDefaults.standard.bool(forKey: Self.demoSignedInKey) { await mockAPI.signIn() }
            me = try? await mockAPI.me()
        } else if Keychain.token != nil {
            do {
                me = try await api.me()
            } catch {
                me = .signedOut
                if case APIError.sessionExpired = error { Keychain.token = nil }
            }
        } else {
            me = .signedOut
        }
        if isSignedIn { await loadAll() }
    }

    /// Opens the World ID sign-in browser flow and, on success, stores the session and loads app data.
    func signInWithWorldID() async throws {
        demoMode = false
        let backend = URL(string: backendURLString) ?? URL(string: Self.defaultBackend)!
        let token = try await WorldSignInController().signIn(backendBase: backend)
        Keychain.token = token
        await loadSession()
    }

    /// "Explore demo" — no network, just flips the mock API into a signed-in state.
    func signInWithDemo() async {
        demoMode = true
        UserDefaults.standard.set(true, forKey: Self.demoSignedInKey)
        await mockAPI.signIn()
        await loadSession()
    }

    func signOut() async {
        try? await api.logout()
        UserDefaults.standard.set(false, forKey: Self.demoSignedInKey)
        clearSessionLocally()
    }

    func replayIntro() {
        onboardingSeen = false
    }

    func loadAll() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            try await run {
                async let r = api.fetchRequests()
                async let a = api.fetchApprovals()
                async let b = api.fetchBudgets()
                requests = try await r
                approvals = try await a
                budgets = try await b
            }
        } catch APIError.sessionExpired {
            // handled in run(): local session already cleared, UI falls back to sign-in.
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
        try await run { try await api.chat(requestId: requestId, message: message) }
    }

    func submitDraft(_ draft: RequestDraft) async throws {
        let created = try await run { try await api.createRequest(draft) }
        requests.insert(created, at: 0)
    }

    func updateBudget(name: String, limitUsd: Double, pct: Double?) async throws {
        let updated = try await run { try await api.updateBudget(name: name, limitUsd: limitUsd, pct: pct) }
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

    /// Starts the World ID for Agents linking flow ("this agent works for me").
    func startWorldLink() async throws -> WorldLink {
        let link = try await api.linkWorldID()
        if demoMode { Task { await mockAPI.simulateWorldLinkCompletion(linkId: link.linkId) } }
        return link
    }

    func worldLinkStatus(id: String) async throws -> WorldLinkStatusResponse {
        try await api.fetchWorldLinkStatus(id: id)
    }
}
