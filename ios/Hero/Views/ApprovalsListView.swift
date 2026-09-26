import SwiftUI

struct ApprovalsListView: View {
    @Environment(Store.self) private var store

    private var pending: [Approval] {
        store.approvals.filter { $0.status == .pending }
    }
    private var resolved: [Approval] {
        store.approvals.filter { $0.status != .pending }
    }

    var body: some View {
        @Bindable var store = store
        NavigationStack(path: $store.approvalsPath) {
            VStack(spacing: 0) {
                if store.budgets?.wallet.worldLinked != true {
                    WorldIDNudgeBanner()
                    HairlineDivider()
                }
                Group {
                    if store.approvals.isEmpty {
                        ContentUnavailableView(
                            "No approvals",
                            systemImage: "checkmark.shield",
                            description: Text("Purchases above your auto-buy limit will show up here.")
                        )
                    } else {
                        List {
                            if !pending.isEmpty {
                                Section("Pending") {
                                    ForEach(pending) { approval in
                                        NavigationLink(value: approval.orderId) {
                                            ApprovalRow(approval: approval)
                                        }
                                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                                        .listRowSeparatorTint(Theme.border)
                                        .listRowBackground(Theme.background)
                                    }
                                }
                            }
                            if !resolved.isEmpty {
                                Section("Resolved") {
                                    ForEach(resolved) { approval in
                                        NavigationLink(value: approval.orderId) {
                                            ApprovalRow(approval: approval)
                                        }
                                        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                                        .listRowSeparatorTint(Theme.border)
                                        .listRowBackground(Theme.background)
                                    }
                                }
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                    }
                }
            }
            .background(Theme.background)
            .navigationTitle("Approvals")
            .navigationDestination(for: String.self) { orderId in
                if let approval = store.approval(id: orderId) {
                    ApprovalDetailView(approval: approval)
                }
            }
            .refreshable { await store.loadAll() }
        }
    }
}

/// Reminder shown when the agent isn't linked to World ID yet — approvals can't be confirmed without it.
/// A quiet banner, not a boxed card: the World ID surface itself only appears once there's an
/// actual code to confirm.
private struct WorldIDNudgeBanner: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Link World ID so the agent can ask you for approval on important purchases.")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
            WorldIDLinkRow(worldLinked: false)
        }
        .padding(.horizontal, Theme.spacingM)
        .padding(.vertical, Theme.spacingM)
        .background(Theme.secondaryBackground)
    }
}

private struct ApprovalRow: View {
    let approval: Approval

    var body: some View {
        HStack(spacing: 12) {
            ProductThumbnail(imageUrl: approval.imageUrl, category: "", size: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text(approval.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                Text(approval.merchant).font(.caption).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(approval.price.usd).font(.subheadline.monospacedDigit().weight(.semibold)).foregroundStyle(Theme.textPrimary)
                StatusDot(color: color, label: approval.status.rawValue.capitalized)
            }
        }
        .padding(.vertical, 10)
    }

    private var color: Color {
        switch approval.status {
        case .pending: return Theme.accentAmber
        case .approved, .paid: return Theme.accentGreen
        case .denied, .expired: return Theme.accentRed
        }
    }
}
