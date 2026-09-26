import Foundation

// MARK: - Enums

enum RequestStatus: String, Codable, CaseIterable {
    case watching
    case readyToBuy
    case needsApproval
    case bought
    case expired
}

enum ApprovalStatus: String, Codable {
    case pending
    case approved
    case denied
    case expired
    case paid
}

/// Status of a World ID for Agents link/verification flow (POST api/world/link, GET api/world/link/{id}).
enum WorldLinkStatus: String, Codable {
    case pending
    case linked
    case denied
    case expired
}

// MARK: - Core models (match backend contract exactly)

struct PricePoint: Codable, Identifiable, Hashable {
    var date: Date
    var price: Double
    var id: Date { date }
}

struct SaleEvent: Codable, Identifiable, Hashable {
    var date: Date
    var name: String
    var id: String { "\(name)-\(date.timeIntervalSince1970)" }
}

struct ActivityEntry: Codable, Identifiable, Hashable {
    var date: Date
    var text: String
    var txHash: String?
    var id: String { "\(date.timeIntervalSince1970)-\(text)" }
}

struct Strategy: Codable, Hashable {
    var summary: String
    var bullets: [String]
    var buyBy: Date
    var confidence: Double
}

struct HeroRequest: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var query: String
    var imageUrl: String?
    var category: String
    var ensName: String
    var autoUsd: Double
    var maxUsd: Double
    var deadline: Date
    var status: RequestStatus
    var currentPrice: Double
    var targetPrice: Double?
    var merchant: String?
    var strategy: Strategy?
    var priceHistory: [PricePoint]
    var events: [SaleEvent]
    var activity: [ActivityEntry]
    var boughtAt: Date? = nil
}

/// Draft parsed by the AI agent from a chat message, editable before writing to ENS.
struct RequestDraft: Codable, Hashable {
    var title: String
    var query: String
    var category: String
    var autoUsd: Double
    var maxUsd: Double
    var deadline: Date
}

struct ChatReply: Codable {
    var reply: String
    var draft: RequestDraft?
}

struct Approval: Codable, Identifiable, Hashable {
    var orderId: String
    var requestId: String
    var title: String
    var imageUrl: String?
    var merchant: String
    var payTo: String
    var price: Double
    var autoUsd: Double
    var maxUsd: Double
    var orderHash: String
    var approvalUrl: String
    var expiresAt: Date
    var status: ApprovalStatus
    var txHash: String?
    var denyReason: String? = nil
    /// Present when this approval uses the World ID for Agents device flow: `approvalUrl` is then
    /// the sandbox verification page and the human confirms this code there.
    var userCode: String? = nil
    var id: String { orderId }
}

/// POST api/world/link response: a one-time "this agent works for me" World ID verification.
struct WorldLink: Codable, Hashable, Identifiable {
    var linkId: String
    var userCode: String
    var approvalUrl: String
    var expiresAt: Date
    var id: String { linkId }
}

/// GET api/world/link/{id} response.
struct WorldLinkStatusResponse: Codable {
    var status: WorldLinkStatus
    var error: String? = nil
}

struct Category: Codable, Identifiable, Hashable {
    var name: String
    var ensName: String
    var limitUsd: Double
    var spentUsd: Double
    var pct: Double?
    var periodEnds: Date
    var id: String { name }
}

struct Wallet: Codable, Hashable {
    var address: String
    var ensRoot: String
    var usdcBalance: Double
    var allowance: Double
    var agent: String
    /// True once the human has linked World ID to this agent ("this agent works for me").
    var worldLinked: Bool? = nil
}

struct BudgetsResponse: Codable {
    var wallet: Wallet
    var categories: [Category]
}

/// GET api/me — current Sign in with World ID state.
struct Me: Codable {
    var signedIn: Bool
    var sub: String?
    var authTime: Date?
    var acr: String?
    var worldLinked: Bool
    var wallet: String?
    var ensRoot: String?

    static let signedOut = Me(signedIn: false, sub: nil, authTime: nil, acr: nil, worldLinked: false, wallet: nil, ensRoot: nil)
}

/// The `acr` value World ID reports for an Orb-verified human (see backend `worldid.ts`).
let orbVerifiedAcr = "https://world.org/oidc/acr/orb-v3"
