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
                                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                                    .listRowSeparator(.hidden)
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
                                    .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                                    .listRowSeparator(.hidden)
                                    .listRowBackground(Theme.background)
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
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

private struct ApprovalRow: View {
    let approval: Approval

    var body: some View {
        HStack(spacing: 12) {
            ProductThumbnail(imageUrl: approval.imageUrl, category: "")
            VStack(alignment: .leading, spacing: 4) {
                Text(approval.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                Text(approval.merchant).font(.caption).foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 4) {
                Text(approval.price.usd).font(.subheadline.monospacedDigit().weight(.semibold)).foregroundStyle(Theme.textPrimary)
                statusLabel
            }
        }
        .padding(12)
        .background(Theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
    }

    private var statusLabel: some View {
        Text(approval.status.rawValue.capitalized)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(color)
    }

    private var color: Color {
        switch approval.status {
        case .pending: return Theme.accentAmber
        case .approved, .paid: return Theme.accentGreen
        case .denied, .expired: return Theme.accentRed
        }
    }
}
