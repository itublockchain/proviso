import SwiftUI

struct RequestsListView: View {
    @Environment(Store.self) private var store
    @State private var searchText = ""
    @State private var ordersOnly = false

    private var filtered: [HeroRequest] {
        var base = store.requests
        if ordersOnly { base = base.filter { $0.order != nil && $0.order?.status != "delivered" } }
        guard !searchText.isEmpty else { return base }
        return base.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !store.requests.isEmpty {
                    RequestsSummaryHeader(requests: store.requests, spentThisMonth: spentThisMonth, ordersOnly: $ordersOnly)
                    HairlineDivider()
                }
                Group {
                    if store.isLoading && store.requests.isEmpty {
                        ProgressView()
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if filtered.isEmpty {
                        ContentUnavailableView(
                            "No requests yet",
                            systemImage: "cart",
                            description: Text("Tap + to tell Hero what to buy.")
                        )
                    } else {
                        List {
                            ForEach(filtered) { request in
                                // Hidden link: whole row is tappable, no disclosure chevron.
                                RequestRow(request: request)
                                    .background(NavigationLink(value: request.id) { EmptyView() }.opacity(0))
                                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
                                .listRowSeparatorTint(Theme.border)
                                .listRowBackground(Theme.background)
                                .swipeActions(edge: .trailing) {
                                    Button(role: .destructive) {
                                        // ponytail: local-only removal, real delete needs a backend endpoint.
                                        store.requests.removeAll { $0.id == request.id }
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                                .contextMenu {
                                    Button("View strategy", systemImage: "sparkles") {}
                                }
                            }
                        }
                        .listStyle(.plain)
                        .scrollContentBackground(.hidden)
                    }
                }
            }
            .background(Theme.background)
            .navigationTitle(heroAppName)
            .searchable(text: $searchText, prompt: "Search requests")
            .navigationDestination(for: String.self) { id in
                if let request = store.request(id: id) {
                    RequestDetailView(request: request)
                }
            }
            .refreshable { await store.loadAll() }
        }
    }

    private var spentThisMonth: Double {
        store.budgets?.categories.reduce(0) { $0 + $1.spentUsd } ?? 0
    }
}

/// Quiet stat strip above the list — total watching, needs approval, spent this month, and
/// orders in transit (tap to filter the list down to those — the lightweight "Orders" place).
private struct RequestsSummaryHeader: View {
    let requests: [HeroRequest]
    let spentThisMonth: Double
    @Binding var ordersOnly: Bool

    private var watching: Int { requests.filter { $0.status == .watching }.count }
    private var needsApproval: Int { requests.filter { $0.status == .needsApproval }.count }
    private var inTransit: Int { requests.compactMap(\.order).filter { $0.status != "delivered" }.count }

    var body: some View {
        HStack(spacing: Theme.spacingL) {
            stat("Watching", "\(watching)")
            stat("Needs approval", "\(needsApproval)", color: needsApproval > 0 ? Theme.accentAmber : Theme.textPrimary)
            stat("Spent this month", spentThisMonth.usd)
            if inTransit > 0 {
                Button { ordersOnly.toggle() } label: {
                    stat("In transit", "\(inTransit)", color: ordersOnly ? Theme.accentBlue : Theme.textPrimary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, Theme.spacingM)
        .padding(.vertical, Theme.spacingS)
    }

    private func stat(_ label: String, _ value: String, color: Color = Theme.textPrimary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.subheadline.weight(.semibold)).monospacedDigit().foregroundStyle(color)
            Text(label).font(.caption2).foregroundStyle(Theme.textSecondary)
        }
    }
}

private struct RequestRow: View {
    let request: HeroRequest

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ProductThumbnail(imageUrl: request.imageUrl, category: request.category, size: 44)

            VStack(alignment: .leading, spacing: 4) {
                Text(request.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                StatusDot(color: request.status.color, label: statusText)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 2) {
                Text(request.currentPrice.usd)
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                    .foregroundStyle(Theme.textPrimary)
                if let target = request.targetPrice, request.status != .bought {
                    Text("target \(target.usd)")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusText: String {
        switch request.status {
        case .bought:
            if let order = request.order { return order.status.capitalized }
            return "Bought \((request.boughtAt ?? request.deadline).formatted(date: .abbreviated, time: .omitted))"
        default:
            return request.status.label
        }
    }
}
