import Foundation

/// Generates a 90-day price history with a dip near a sale date, for realistic-looking charts.
private func priceHistory(base: Double, dipAt daysAgo: Int, dipDepth: Double, noise: Double = 4) -> [PricePoint] {
    let now = Date()
    var points: [PricePoint] = []
    var seed: UInt64 = 42
    func rand() -> Double {
        seed = seed &* 6364136223846793005 &+ 1
        return Double(seed >> 33) / Double(UInt64.max >> 33)
    }
    for day in stride(from: 90, through: 0, by: -3) {
        let date = Calendar.current.date(byAdding: .day, value: -day, to: now)!
        let distanceFromDip = abs(day - daysAgo)
        let dipInfluence = max(0, 1 - Double(distanceFromDip) / 10.0)
        let price = base - dipDepth * dipInfluence + (rand() - 0.5) * noise
        points.append(PricePoint(date: date, price: (price * 100).rounded() / 100))
    }
    return points
}

/// Central fixture set backing MockAPI. Kept in one place so the demo stays coherent.
enum MockData {
    static let now = Date()
    private static let cal = Calendar.current

    static func daysFromNow(_ n: Int) -> Date { cal.date(byAdding: .day, value: n, to: now)! }
    static func daysAgo(_ n: Int) -> Date { cal.date(byAdding: .day, value: -n, to: now)! }

    static let sonyTV = HeroRequest(
        id: "req-sony-tv",
        title: "Sony 55\" TV",
        query: "I want a Sony 55\" TV, must arrive within 1 month, never above $500, buy on your own under $400",
        imageUrl: nil,
        category: "Hobby",
        ensName: "sony-tv.hobby.alice.eth",
        autoUsd: 400,
        maxUsd: 500,
        deadline: daysFromNow(28),
        status: .watching,
        currentPrice: 439,
        targetPrice: 389,
        merchant: "BestBuy",
        strategy: Strategy(
            summary: "Price is ~12% inflated right now. Waiting for the 11.11 sale window before buying.",
            bullets: [
                "Current price $439 is 12% above the 90-day median of $392.",
                "11.11 sale historically drops this model 15-18% for ~4 days.",
                "Waiting ~2 weeks keeps a comfortable buffer before your Oct 24 deadline.",
                "Target buy price: $389, well under your $400 auto-buy limit."
            ],
            buyBy: daysFromNow(20),
            confidence: 0.82
        ),
        priceHistory: priceHistory(base: 430, dipAt: 15, dipDepth: 60),
        events: [
            SaleEvent(date: daysFromNow(30), name: "11.11 Sale"),
            SaleEvent(date: cal.date(from: DateComponents(year: 2026, month: 11, day: 27))!, name: "Black Friday")
        ],
        activity: [
            ActivityEntry(date: daysAgo(3), text: "Policy written to ENS", txHash: "0x4f2a...9c31"),
            ActivityEntry(date: daysAgo(1), text: "Agent checked price: $439, waiting", txHash: nil)
        ]
    )

    static let ps5 = HeroRequest(
        id: "req-ps5",
        title: "PlayStation 5",
        query: "Grab a PS5 disc edition, must arrive in 2 weeks, max $500, auto-buy under $400",
        imageUrl: nil,
        category: "Hobby",
        ensName: "ps5.hobby.alice.eth",
        autoUsd: 400,
        maxUsd: 500,
        deadline: daysFromNow(12),
        status: .needsApproval,
        currentPrice: 449,
        targetPrice: 420,
        merchant: "Amazon (verified)",
        strategy: Strategy(
            summary: "Found a verified listing at $449. This is above your $400 auto-buy limit, so it needs your approval.",
            bullets: [
                "Deadline is close (12 days) — waiting further risks missing arrival window.",
                "$449 is within your $500 max but above the $400 auto-buy threshold.",
                "Merchant is verified; requesting human approval via World ID before purchase."
            ],
            buyBy: daysFromNow(5),
            confidence: 0.74
        ),
        priceHistory: priceHistory(base: 460, dipAt: 40, dipDepth: 30),
        events: [
            SaleEvent(date: daysFromNow(3), name: "Flash Deal")
        ],
        activity: [
            ActivityEntry(date: daysAgo(5), text: "Policy written to ENS", txHash: "0x9ab1...11ef"),
            ActivityEntry(date: daysAgo(0), text: "Order held pending approval", txHash: "0x71cd...aa02")
        ]
    )

    static let lego = HeroRequest(
        id: "req-lego",
        title: "LEGO Millennium Falcon",
        query: "Buy the LEGO Millennium Falcon set whenever it drops under $650",
        imageUrl: nil,
        category: "Hobby",
        ensName: "lego-falcon.hobby.alice.eth",
        autoUsd: 650,
        maxUsd: 700,
        deadline: daysAgo(-2),
        status: .bought,
        currentPrice: 609,
        targetPrice: 609,
        merchant: "LEGO Store (verified)",
        strategy: Strategy(
            summary: "Bought at $609 during a flash sale, well under your $650 auto-buy limit.",
            bullets: [
                "Price dropped to $609 during a surprise flash sale.",
                "Below your $650 auto-buy threshold — purchased immediately, no approval needed."
            ],
            buyBy: daysAgo(10),
            confidence: 0.95
        ),
        priceHistory: priceHistory(base: 700, dipAt: 12, dipDepth: 90, noise: 6),
        events: [
            SaleEvent(date: daysAgo(12), name: "Flash Sale")
        ],
        activity: [
            ActivityEntry(date: daysAgo(20), text: "Policy written to ENS", txHash: "0x1234...beef"),
            ActivityEntry(date: daysAgo(12), text: "Agent bought item: $609", txHash: "0xdead...5678"),
            ActivityEntry(date: daysAgo(12), text: "USDC transferred to merchant", txHash: "0xf00d...cafe")
        ]
    )

    static let switch2 = HeroRequest(
        id: "req-switch",
        title: "Nintendo Switch 2",
        query: "Get me a Switch 2 within budget, deadline was last week",
        imageUrl: nil,
        category: "Needs",
        ensName: "switch2.needs.alice.eth",
        autoUsd: 350,
        maxUsd: 400,
        deadline: daysAgo(4),
        status: .expired,
        currentPrice: 449,
        targetPrice: nil,
        merchant: nil,
        strategy: Strategy(
            summary: "Price never dropped below your $400 max before the deadline passed.",
            bullets: [
                "Price stayed above $430 for the entire window.",
                "Deadline passed without a qualifying price — request expired automatically."
            ],
            buyBy: daysAgo(4),
            confidence: 0.4
        ),
        priceHistory: priceHistory(base: 445, dipAt: 60, dipDepth: 10),
        events: [],
        activity: [
            ActivityEntry(date: daysAgo(30), text: "Policy written to ENS", txHash: "0x5555...0001"),
            ActivityEntry(date: daysAgo(4), text: "Request expired — no purchase made", txHash: nil)
        ]
    )

    static let requests: [HeroRequest] = [sonyTV, ps5, lego, switch2]

    static let approvals: [Approval] = [
        Approval(
            orderId: "order-ps5-1",
            requestId: ps5.id,
            title: ps5.title,
            imageUrl: nil,
            merchant: "Amazon (verified)",
            payTo: "0xA1b2C3d4E5f6789012345678901234567890AbCd",
            price: 449,
            autoUsd: 400,
            maxUsd: 500,
            orderHash: "0x71cd8f...aa029e",
            approvalUrl: "https://sandbox.auth.world.org/verify/order-ps5-1",
            expiresAt: daysFromNow(1),
            status: .pending,
            txHash: nil,
            userCode: "WRLD-7F2A"
        )
    ]

    static let hobbyCategory = Category(
        name: "Hobby",
        ensName: "hobby.alice.eth",
        limitUsd: 1000,
        spentUsd: 700,
        pct: nil,
        periodEnds: daysFromNow(18)
    )

    static let needsCategory = Category(
        name: "Needs",
        ensName: "needs.alice.eth",
        limitUsd: 3000,
        spentUsd: 1150,
        pct: 0.1,
        periodEnds: daysFromNow(18)
    )

    static let wallet = Wallet(
        address: "0x8f3CfA1c2B4d5E6f7A8b9C0d1E2f3A4b5C6d7E8f",
        ensRoot: "alice.eth",
        usdcBalance: 8420,
        allowance: 5000,
        agent: "0x0Agent1234567890AbCdEf1234567890AbCdEf12"
    )
}

/// Fully offline API implementation backed by MockData. Default so the app demos without a backend.
actor MockAPI: API {
    private var requests: [HeroRequest] = MockData.requests
    private var approvals: [Approval] = MockData.approvals
    private var categories: [Category] = [MockData.hobbyCategory, MockData.needsCategory]
    private var worldLinked = false
    private var pendingWorldLinkId: String?
    private var signedIn = false
    private var walletStatus: WalletStatus = .none

    func chat(requestId: String?, message: String) async throws -> ChatReply {
        try? await Task.sleep(for: .milliseconds(500))
        let draft = Self.parseDraft(from: message)
        let reply = "Got it — here's a draft based on \"\(message)\". Adjust the numbers below, then write it to ENS."
        return ChatReply(reply: reply, draft: draft)
    }

    /// Very small heuristic parser: pulls a dollar amount as maxUsd and guesses a title/category.
    /// ponytail: naive keyword matching, swap for a real LLM call once the backend exists.
    private static func parseDraft(from message: String) -> RequestDraft {
        let lower = message.lowercased()
        let numbers = message.split(separator: " ").compactMap { token -> Double? in
            let cleaned = token.filter { $0.isNumber || $0 == "." }
            return Double(cleaned)
        }
        let maxUsd = numbers.max() ?? 400
        let autoUsd = numbers.count > 1 ? numbers.min() ?? maxUsd * 0.8 : maxUsd * 0.8
        let category = lower.contains("need") || lower.contains("grocer") ? "Needs" : "Hobby"
        let title = message.split(separator: ",").first.map(String.init) ?? message
        return RequestDraft(
            title: title.trimmingCharacters(in: .whitespaces),
            query: message,
            category: category,
            autoUsd: (autoUsd * 100).rounded() / 100,
            maxUsd: (maxUsd * 100).rounded() / 100,
            deadline: MockData.daysFromNow(30)
        )
    }

    func createRequest(_ draft: RequestDraft) async throws -> HeroRequest {
        let new = HeroRequest(
            id: "req-\(UUID().uuidString.prefix(8))",
            title: draft.title,
            query: draft.query,
            imageUrl: nil,
            category: draft.category,
            ensName: "\(draft.title.lowercased().replacingOccurrences(of: " ", with: "-")).\(draft.category.lowercased()).alice.eth",
            autoUsd: draft.autoUsd,
            maxUsd: draft.maxUsd,
            deadline: draft.deadline,
            status: .watching,
            currentPrice: draft.maxUsd,
            targetPrice: draft.autoUsd,
            merchant: nil,
            strategy: Strategy(
                summary: "Analyzing 90-day price history to find the best time to buy.",
                bullets: ["Just created — the agent will check prices daily and update this strategy."],
                buyBy: draft.deadline,
                confidence: 0.5
            ),
            priceHistory: [PricePoint(date: MockData.now, price: draft.maxUsd)],
            events: [],
            activity: [ActivityEntry(date: MockData.now, text: "Policy written to ENS", txHash: "0xnew...\(UUID().uuidString.prefix(4))")]
        )
        requests.insert(new, at: 0)
        return new
    }

    func fetchRequests() async throws -> [HeroRequest] { requests }

    func fetchRequest(id: String) async throws -> HeroRequest {
        guard let r = requests.first(where: { $0.id == id }) else { throw APIError.badResponse }
        return r
    }

    func fetchApprovals() async throws -> [Approval] { approvals }

    func fetchApproval(id: String) async throws -> Approval {
        guard let a = approvals.first(where: { $0.orderId == id }) else { throw APIError.badResponse }
        return a
    }

    func fetchBudgets() async throws -> BudgetsResponse {
        var wallet = MockData.wallet
        wallet.worldLinked = worldLinked
        return BudgetsResponse(wallet: wallet, categories: categories)
    }

    func updateBudget(name: String, limitUsd: Double, pct: Double?) async throws -> Category {
        guard let idx = categories.firstIndex(where: { $0.name == name }) else { throw APIError.badResponse }
        categories[idx].limitUsd = limitUsd
        categories[idx].pct = pct
        return categories[idx]
    }

    /// Simulates a World ID approval completing after a short delay, for the polling demo in ApprovalDetailView.
    func simulateApprovalCompletion(orderId: String) async {
        try? await Task.sleep(for: .seconds(4))
        if let idx = approvals.firstIndex(where: { $0.orderId == orderId }) {
            approvals[idx].status = .approved
            try? await Task.sleep(for: .seconds(1))
            approvals[idx].status = .paid
            approvals[idx].txHash = "0xpaid...\(UUID().uuidString.prefix(6))"
        }
    }

    func linkWorldID() async throws -> WorldLink {
        let id = "link-\(UUID().uuidString.prefix(8))"
        pendingWorldLinkId = id
        return WorldLink(
            linkId: id,
            userCode: Self.randomUserCode(),
            approvalUrl: "https://sandbox.auth.world.org/verify/\(id)",
            expiresAt: MockData.daysFromNow(1)
        )
    }

    func fetchWorldLinkStatus(id: String) async throws -> WorldLinkStatusResponse {
        guard pendingWorldLinkId == id else { return WorldLinkStatusResponse(status: .expired) }
        return WorldLinkStatusResponse(status: worldLinked ? .linked : .pending)
    }

    /// Simulates the human linking World ID after a short delay, for the Budgets/Settings polling demo.
    func simulateWorldLinkCompletion(linkId: String) async {
        try? await Task.sleep(for: .seconds(4))
        guard pendingWorldLinkId == linkId else { return }
        worldLinked = true
    }

    /// "Explore demo" flips this on — no network, just an in-memory mock session.
    func signIn() { signedIn = true }

    func me() async throws -> Me {
        guard signedIn else { return .signedOut }
        let hasWallet = walletStatus == .ready || walletStatus == .demo
        return Me(
            signedIn: true,
            sub: "demo0badc0de",
            authTime: MockData.now,
            acr: orbVerifiedAcr,
            worldLinked: worldLinked,
            wallet: hasWallet ? MockData.wallet.address : nil,
            ensRoot: hasWallet ? MockData.wallet.ensRoot : nil,
            walletStatus: walletStatus
        )
    }

    func logout() async throws { signedIn = false }

    /// POST api/wallet/start — fake MetaMask deep link + fallback page; Store.startWallet()
    /// schedules simulateWalletReady() right after this in demo mode.
    func startWallet(handle: String?) async throws -> WalletStart {
        walletStatus = .provisioning
        let token = UUID().uuidString.prefix(10).lowercased()
        return WalletStart(
            url: "https://link.metamask.io/dapp/hero-demo.ngrok-free.dev/w/\(token)",
            pageUrl: "https://hero-demo.ngrok-free.dev/w/\(token)"
        )
    }

    /// POST api/wallet/demo — switches the mock account to the Hero-held demo wallet right away.
    func useDemoWallet() async throws { walletStatus = .demo }

    /// Simulates the user finishing the 3 MetaMask signatures a few seconds after startWallet().
    func simulateWalletReady() async {
        try? await Task.sleep(for: .seconds(4))
        if walletStatus == .provisioning { walletStatus = .ready }
    }

    /// Price before the first demo lever pull per request, restored by `.reset`.
    private var demoFrom: [String: Double] = [:]

    /// Mirrors POST api/requests/{id}/demo: same bands, same activity lines, no chain.
    func demo(requestId: String, scenario: DemoScenario) async throws -> HeroRequest {
        try? await Task.sleep(for: .milliseconds(400))
        guard let i = requests.firstIndex(where: { $0.id == requestId }) else { throw APIError.badResponse }
        var r = requests[i]
        let now = Date()
        func log(_ text: String, blocked: Bool? = nil, tx: String? = nil) {
            r.activity.append(ActivityEntry(date: now, text: text, txHash: tx, blocked: blocked))
        }
        if scenario == .reset {
            approvals.removeAll { $0.requestId == requestId && ($0.status == .pending || $0.status == .approved) }
            r.status = .watching
            r.boughtAt = nil
            if let from = demoFrom.removeValue(forKey: requestId) {
                r.currentPrice = from
                r.priceHistory.append(PricePoint(date: now, price: from))
            }
            log("Demo reset: watching again")
        } else {
            guard r.status == .watching else { throw APIError.server("not_watching") }
            guard let price = Self.demoPrice(scenario, current: r.currentPrice, auto: r.autoUsd, max: r.maxUsd) else {
                throw APIError.server("no_band")
            }
            if demoFrom[requestId] == nil { demoFrom[requestId] = r.currentPrice }
            r.currentPrice = price
            r.priceHistory.append(PricePoint(date: now, price: price))
            switch scenario {
            case .auto:
                r.status = .bought
                r.boughtAt = now
                r.strategy?.summary = "Price dropped into your auto band, so I bought it on my own."
                log("Bought for \(price.usd) (auto band)", tx: "0xdemo...\(UUID().uuidString.prefix(6))")
            case .approval:
                let code = Self.randomUserCode()
                approvals.insert(Approval(
                    orderId: "order-\(UUID().uuidString.prefix(8))", requestId: r.id, title: r.title, imageUrl: r.imageUrl,
                    merchant: r.merchant ?? "Verified merchant", payTo: "0x000000000000000000000000000000000000dEaD",
                    price: price, autoUsd: r.autoUsd, maxUsd: r.maxUsd, orderHash: "0x\(UUID().uuidString.prefix(12))",
                    approvalUrl: "https://sandbox.auth.world.org/device?user_code=\(code)",
                    expiresAt: now.addingTimeInterval(600), status: .pending, txHash: nil, userCode: code
                ), at: 0)
                r.status = .needsApproval
                r.strategy?.summary = "Price is in your approval band. Waiting for you to confirm with World ID."
                log("\(price.usd) is above auto \(r.autoUsd.usd): asked you to confirm with World ID (code \(code))")
            case .blocked:
                r.strategy?.summary = "Price is above your max. The contract will not let me buy, so I keep watching."
                log("Above your \(r.maxUsd.usd) max at \(price.usd) — not bought", blocked: true)
            case .attack:
                r.strategy?.summary = "A checkout tried to redirect the payment. The contract refused it; still watching."
                log("Prompt-injected checkout tried to pay 0x…bad1 — blocked by the contract (UnverifiedMerchant), rejected before sending", blocked: true)
            case .reset:
                break
            }
        }
        requests[i] = r
        return r
    }

    /// Same band math as the backend's `demoPrice`: auto/attack land ≤ auto, approval in (auto, max], blocked > max.
    static func demoPrice(_ s: DemoScenario, current: Double, auto: Double, max maxUsd: Double) -> Double? {
        func c(_ x: Double) -> Double { (x * 100).rounded() / 100 }
        func under(_ x: Double) -> Double { c(x.rounded(.down) - 0.01) } // x.99 strictly below x
        let mid = (auto + maxUsd) / 2
        switch s {
        case .approval:
            let p = under(mid) > auto ? under(mid) : c(mid)
            return p > auto && p <= maxUsd ? p : nil
        case .blocked:
            return max(under(maxUsd * 1.08), c(maxUsd + 1))
        case .auto, .attack:
            let p = max(under(min(current, auto * 0.95)), c(auto / 2))
            return p > 0 && p <= auto ? p : nil
        case .reset:
            return nil
        }
    }

    private static func randomUserCode() -> String {
        let letters = "ABCDEFGHJKLMNPQRSTUVWXYZ"
        func group() -> String { String((0..<4).map { _ in letters.randomElement()! }) }
        return "\(group())-\(group())"
    }
}
