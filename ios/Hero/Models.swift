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
    var id: String { orderId }
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
}

struct BudgetsResponse: Codable {
    var wallet: Wallet
    var categories: [Category]
}
