import SwiftUI
import UIKit

/// App-wide product name constant.
let heroAppName = "Hero"

extension Color {
    /// A color that adapts between light and dark mode without needing an asset catalog entry.
    init(light: UIColor, dark: UIColor) {
        self.init(uiColor: UIColor { trait in
            trait.userInterfaceStyle == .dark ? dark : light
        })
    }
}

enum Theme {
    static let background = Color(light: UIColor(hex: 0xF7F7F8), dark: UIColor(hex: 0x0F0F10))
    static let cardBackground = Color(light: UIColor(hex: 0xFFFFFF), dark: UIColor(hex: 0x1C1C1F))
    static let secondaryBackground = Color(light: UIColor(hex: 0xF0F0F2), dark: UIColor(hex: 0x161618))
    static let border = Color(light: UIColor(hex: 0xE2E2E5), dark: UIColor(hex: 0x2A2A2E))
    static let textPrimary = Color(light: UIColor(hex: 0x111113), dark: UIColor(hex: 0xF5F5F7))
    static let textSecondary = Color(light: UIColor(hex: 0x6E6E73), dark: UIColor(hex: 0x8E8E93))

    static let accentGreen = Color(light: UIColor(hex: 0x1E8E3E), dark: UIColor(hex: 0x34C759))
    static let accentAmber = Color(light: UIColor(hex: 0xB86E00), dark: UIColor(hex: 0xFFB020))
    static let accentBlue = Color(light: UIColor(hex: 0x0A66FF), dark: UIColor(hex: 0x4C9BFF))
    static let accentRed = Color(light: UIColor(hex: 0xD70015), dark: UIColor(hex: 0xFF453A))

    static let cardCorner: CGFloat = 16
    static let cardPadding: CGFloat = 16
}

private extension UIColor {
    convenience init(hex: UInt32) {
        let r = CGFloat((hex >> 16) & 0xFF) / 255.0
        let g = CGFloat((hex >> 8) & 0xFF) / 255.0
        let b = CGFloat(hex & 0xFF) / 255.0
        self.init(red: r, green: g, blue: b, alpha: 1.0)
    }
}

/// Reusable card container matching the Hero design language: rounded corners, hairline border.
struct HeroCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(Theme.cardPadding)
            .background(Theme.cardBackground)
            .clipShape(RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous)
                    .strokeBorder(Theme.border, lineWidth: 1)
            )
    }
}

/// Status pill used across Requests list and detail.
struct StatusPill: View {
    let status: RequestStatus

    var body: some View {
        Text(status.label)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(status.color.opacity(0.16))
            .foregroundStyle(status.color)
            .clipShape(Capsule())
    }
}

extension RequestStatus {
    var label: String {
        switch self {
        case .watching: return "Watching"
        case .readyToBuy: return "Ready to buy"
        case .needsApproval: return "Needs approval"
        case .bought: return "Bought"
        case .expired: return "Expired"
        }
    }

    var color: Color {
        switch self {
        case .watching: return Theme.accentBlue
        case .readyToBuy: return Theme.accentGreen
        case .needsApproval: return Theme.accentAmber
        case .bought: return Theme.accentGreen
        case .expired: return Theme.accentRed
        }
    }
}

extension Double {
    var usd: String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: self)) ?? "$\(Int(self))"
    }
}

extension String {
    /// Best-effort SF Symbol + tint for a request category, used as a thumbnail placeholder
    /// when no product image is available.
    var categoryIcon: (symbol: String, tint: Color) {
        switch self.lowercased() {
        case "hobby": return ("gamecontroller.fill", Theme.accentBlue)
        case "needs": return ("cart.fill", Theme.accentGreen)
        case "electronics", "tech": return ("laptopcomputer", Theme.accentBlue)
        case "home": return ("house.fill", Theme.accentAmber)
        case "fashion", "clothing": return ("tshirt.fill", Theme.accentRed)
        default: return ("bag.fill", Theme.textSecondary)
        }
    }
}

/// Rounded-square product thumbnail: shows the remote image when available, otherwise a
/// tasteful SF Symbol tinted per category.
struct ProductThumbnail: View {
    let imageUrl: String?
    let category: String
    var size: CGFloat = 48

    var body: some View {
        let icon = category.categoryIcon
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(icon.tint.opacity(0.14))
            if let imageUrl, let url = URL(string: imageUrl) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        Image(systemName: icon.symbol)
                            .foregroundStyle(icon.tint)
                    }
                }
            } else {
                Image(systemName: icon.symbol)
                    .font(.system(size: size * 0.4))
                    .foregroundStyle(icon.tint)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
