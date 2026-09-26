import SwiftUI

struct RequestsListView: View {
    @Environment(Store.self) private var store
    @State private var searchText = ""

    private var filtered: [HeroRequest] {
        guard !searchText.isEmpty else { return store.requests }
        return store.requests.filter { $0.title.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        NavigationStack {
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
                            // Hidden link: whole card is tappable, no disclosure chevron.
                            RequestRow(request: request)
                                .background(NavigationLink(value: request.id) { EmptyView() }.opacity(0))
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                            .listRowSeparator(.hidden)
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
}

private struct RequestRow: View {
    let request: HeroRequest

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ProductThumbnail(imageUrl: request.imageUrl, category: request.category)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    Text(request.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    Spacer()
                    StatusPill(status: request.status)
                }

                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(request.currentPrice.usd)
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                    if let target = request.targetPrice, request.status != .bought {
                        Text("target \(target.usd)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(Theme.textSecondary)
                    }
                }

                if let secondary = secondaryLine {
                    Text(secondary)
                        .font(.caption)
                        .foregroundStyle(secondaryColor)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cardCorner, style: .continuous)
                .strokeBorder(Theme.border, lineWidth: 1)
        )
    }

    private var daysLeft: Int {
        Calendar.current.dateComponents([.day], from: Date(), to: request.deadline).day ?? 0
    }

    /// A single line of supporting context beneath the price — never repeats the status pill.
    private var secondaryLine: String? {
        switch request.status {
        case .bought:
            return "Bought \((request.boughtAt ?? request.deadline).formatted(date: .abbreviated, time: .omitted))"
        case .expired:
            return "Deadline \(request.deadline.formatted(date: .abbreviated, time: .omitted))"
        case .watching, .readyToBuy, .needsApproval:
            return daysLeft >= 0 ? "\(daysLeft)d left" : "\(-daysLeft)d overdue"
        }
    }

    private var secondaryColor: Color {
        switch request.status {
        case .bought: return Theme.textSecondary
        case .expired: return Theme.accentRed
        default: return daysLeft <= 5 ? Theme.accentAmber : Theme.textSecondary
        }
    }
}
