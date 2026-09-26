import Foundation
import SwiftUI

/// App-wide observable state. One store, kept small: it owns the API instance and cached data,
/// views read directly from it instead of duplicating fetch logic.
@Observable
@MainActor
final class Store {
    var demoMode: Bool {
        didSet {
            UserDefaults.standard.set(demoMode, forKey: "proviso.demoMode")
            Task { await loadSession() } // switch data source right away
        }
    }
    var backendURLString: String {
        didSet {
            UserDefaults.standard.set(backendURLString, forKey: "proviso.backendURL")
            if !demoMode { Task { await loadSession() } }
        }
    }

    var requests: [ProvisoRequest] = []
    var approvals: [Approval] = []
    var budgets: BudgetsResponse?
    var isLoading = false
    var errorMessage: String?
    var selectedTab = 0
    var showingComposer = false
    var approvalsPath: [String] = []
    var requestsPath: [String] = []
    /// Set by `resetAndStartOver()`; shown as a toast that outlives the switch back to onboarding.
    var toastMessage: String?

    /// Mandatory Sign in with World ID: `nil` while the session is still being checked at launch.
    var me: Me?
    var onboardingSeen: Bool {
        didSet { UserDefaults.standard.set(onboardingSeen, forKey: "proviso.onboardingSeen") }
    }

    enum AuthPhase { case loading, signedOut, signedIn }
    var authPhase: AuthPhase {
        guard let me else { return .loading }
        return me.signedIn ? .signedIn : .signedOut
    }
    var isSignedIn: Bool { me?.signedIn == true }
    var walletStatus: WalletStatus { me?.walletStatus ?? .none }

    private var mockAPI = MockAPI()
    /// Public tunnel to the demo backend, so the app works on a real phone too.
    static let defaultBackend = "https://uncookable-izaiah-dualistic.ngrok-free.dev"
    private static let demoSignedInKey = "proviso.demoSignedIn"

    private var api: API {
        if demoMode {
            return mockAPI
        }
        let url = URL(string: backendURLString) ?? URL(string: Self.defaultBackend)!
        return LiveAPI(baseURL: url)
    }

    init() {
        self.demoMode = UserDefaults.standard.object(forKey: "proviso.demoMode") as? Bool ?? true
        self.backendURLString = UserDefaults.standard.string(forKey: "proviso.backendURL") ?? Self.defaultBackend
        self.onboardingSeen = UserDefaults.standard.bool(forKey: "proviso.onboardingSeen")
    }

    /// Runs an API call, and on a 401 sign-out-required response drops the local session so the
    /// UI falls back to sign-in — the one place that needs to know about that error shape.
    private func run<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch APIError.sessionExpired {
            clearSessionLocally()
            throw APIError.sessionExpired
        } catch let e as URLError {
            throw APIError.server("Can't reach the Proviso server (\(e.localizedDescription)). Check the backend URL in Settings and that it is running.")
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

    func request(id: String) -> ProvisoRequest? {
        requests.first { $0.id == id }
    }

    /// Re-fetches one request — used by RequestDetailView to poll a live order's fulfillment status.
    func refreshRequest(id: String) async {
        guard let updated = try? await run({ try await api.fetchRequest(id: id) })
        else { return }
        if let idx = requests.firstIndex(where: { $0.id == id }) {
            withAnimation(.snappy) { requests[idx] = updated }
        }
    }

    func approval(id: String) -> Approval? {
        approvals.first { $0.orderId == id }
    }

    func sendChat(requestId: String?, message: String) async throws -> ChatReply {
        try await run { try await api.chat(requestId: requestId, message: message) }
    }

    /// Returns as soon as the backend has the request (its setup keeps running); opens its page.
    func submitDraft(_ draft: RequestDraft) async throws {
        let created = try await run { try await api.createRequest(draft) }
        requests.insert(created, at: 0)
        showRequest(created.id)
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

    /// proviso://approval/<orderId> — World App's `return_to` lands here after the user approves.
    /// proviso://wallet?ok=1 — the MetaMask-hosted setup page's best-effort return after wallet setup.
    /// proviso://request/<id> — jumps straight to a request's detail (used for QA/demo deep links).
    func handleDeepLink(_ url: URL) {
        guard url.scheme == "proviso" else { return }
        switch url.host() {
        case "approval":
            guard !url.lastPathComponent.isEmpty, url.lastPathComponent != "/" else { return }
            showApproval(url.lastPathComponent)
        case "wallet":
            Task { await loadSession() }
        case "request":
            guard !url.lastPathComponent.isEmpty, url.lastPathComponent != "/" else { return }
            showRequest(url.lastPathComponent)
        default:
            break
        }
    }

    private func showApproval(_ orderId: String) {
        selectedTab = 1
        if approvalsPath.last != orderId { approvalsPath = [orderId] }
        Task { await refreshApproval(orderId: orderId) }
    }

    private func showRequest(_ id: String) {
        selectedTab = 0
        if requestsPath.last != id { requestsPath = [id] }
    }

    /// Hidden stage controls: moves the price into a band (or resets), then shows the result —
    /// the new pending approval for `.approval`, the updated request otherwise.
    func demo(requestId: String, scenario: DemoScenario) async throws {
        let updated = try await run { try await api.demo(requestId: requestId, scenario: scenario) }
        if let idx = requests.firstIndex(where: { $0.id == requestId }) {
            withAnimation(.snappy) { requests[idx] = updated }
        }
        guard scenario == .approval || scenario == .reset else { return }
        if let list = try? await api.fetchApprovals() { approvals = list }
        guard scenario == .approval,
              let pending = approvals.first(where: { $0.requestId == requestId && $0.status == .pending }) else { return }
        try? await Task.sleep(for: .seconds(1.2)) // let the price land in the amber band first
        showApproval(pending.orderId)
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

    /// Starts wallet setup: returns the MetaMask deep link + fallback page URL. In demo mode,
    /// flips the mock account to "ready" after a few seconds so the polling UI has something to see.
    func startWallet(handle: String?) async throws -> WalletStart {
        let start = try await run { try await api.startWallet(handle: handle) }
        if demoMode { Task { await mockAPI.simulateWalletReady() } }
        return start
    }

    /// "Use demo wallet" — switches the account to the Proviso-held demo wallet.
    func useDemoWallet() async throws {
        try await run { try await api.useDemoWallet() }
        await loadSession()
    }

    /// "Reset & start over": wipes the signed-in account on the backend (chain state, ENS name,
    /// requests/orders) — the session is invalid right after, which is fine, we're about to clear
    /// it locally anyway — then wipes local state so the same wallet + World ID can onboard again.
    /// Any server failure (older/disabled dev endpoint, unreachable backend) still clears local
    /// state: the point of this button is to unblock re-testing, not to gate it on the backend.
    func resetAndStartOver() async {
        let result = try? await api.resetEverything()
        Keychain.token = nil
        UserDefaults.standard.set(false, forKey: Self.demoSignedInKey)
        me = .signedOut
        requests = []
        approvals = []
        budgets = nil
        approvalsPath = []
        requestsPath = []
        errorMessage = nil
        if let result {
            let namePart = result.ens.map { "name \($0) freed, " } ?? ""
            toastMessage = "Reset: contract \(result.chain ? "✓" : "✗"), \(namePart)\(result.requests) requests, \(result.orders) orders"
        } else {
            toastMessage = "Server reset unavailable — local state cleared"
        }
        onboardingSeen = false
    }
}
