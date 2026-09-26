import SwiftUI
import Charts
import SafariServices

struct RequestDetailView: View {
    let request: HeroRequest

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                PriceHistoryChart(request: request)
                if let strategy = request.strategy {
                    StrategyCard(strategy: strategy)
                }
                PolicyCard(request: request)
                ActivityTimeline(activity: request.activity)
            }
            .padding(16)
        }
        .background(Theme.background)
        .navigationTitle(request.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private var header: some View {
        HeroCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(request.title).font(.title2.bold()).foregroundStyle(Theme.textPrimary)
                        if let merchant = request.merchant {
                            Text(merchant).font(.caption).foregroundStyle(Theme.textSecondary)
                        }
                    }
                    Spacer()
                    StatusPill(status: request.status)
                }
                HStack(alignment: .firstTextBaseline, spacing: 16) {
                    priceStat("Current", request.currentPrice)
                    if let target = request.targetPrice {
                        priceStat("Target", target)
                    }
                    priceStat("Auto-buy", request.autoUsd)
                    priceStat("Max", request.maxUsd)
                }
                Text(request.query)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
                    .padding(.top, 4)
            }
        }
    }

    private func priceStat(_ label: String, _ value: Double) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(Theme.textSecondary)
            Text(value.usd).font(.subheadline.monospacedDigit().weight(.semibold)).foregroundStyle(Theme.textPrimary)
        }
    }
}

private struct PriceHistoryChart: View {
    let request: HeroRequest

    var body: some View {
        HeroCard {
            VStack(alignment: .leading, spacing: 8) {
                Text("Price History (90d)").font(.headline).foregroundStyle(Theme.textPrimary)
                Chart {
                    RectangleMark(
                        yStart: .value("Auto", 0),
                        yEnd: .value("Auto", request.autoUsd)
                    )
                    .foregroundStyle(Theme.accentGreen.opacity(0.08))

                    RectangleMark(
                        yStart: .value("Auto", request.autoUsd),
                        yEnd: .value("Max", request.maxUsd)
                    )
                    .foregroundStyle(Theme.accentAmber.opacity(0.08))

                    ForEach(request.priceHistory) { point in
                        LineMark(
                            x: .value("Date", point.date),
                            y: .value("Price", point.price)
                        )
                        .foregroundStyle(Theme.accentBlue)
                        .interpolationMethod(.catmullRom)
                    }

                    ForEach(request.events) { event in
                        RuleMark(x: .value("Event", event.date))
                            .foregroundStyle(Theme.textSecondary.opacity(0.6))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            .annotation(position: .top, alignment: .center) {
                                Text(event.name)
                                    .font(.caption2)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                    }
                }
                .frame(height: 200)
                .chartYAxis {
                    AxisMarks(position: .leading)
                }

                HStack(spacing: 16) {
                    legend(color: Theme.accentGreen, label: "Auto-buy zone")
                    legend(color: Theme.accentAmber, label: "Approval zone")
                }
                .font(.caption2)
            }
        }
    }

    private func legend(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).foregroundStyle(Theme.textSecondary)
        }
    }
}

private struct StrategyCard: View {
    let strategy: Strategy

    var body: some View {
        HeroCard {
            VStack(alignment: .leading, spacing: 10) {
                Label("Agent Strategy", systemImage: "sparkles")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text(strategy.summary)
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(strategy.bullets, id: \.self) { bullet in
                        HStack(alignment: .top, spacing: 6) {
                            Text("•").foregroundStyle(Theme.textSecondary)
                            Text(bullet).font(.footnote).foregroundStyle(Theme.textPrimary)
                        }
                    }
                }
                HStack {
                    Label("Buy by \(strategy.buyBy.formatted(date: .abbreviated, time: .omitted))", systemImage: "calendar")
                    Spacer()
                    Text("\(Int(strategy.confidence * 100))% confidence")
                }
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

private struct PolicyCard: View {
    let request: HeroRequest

    var body: some View {
        HeroCard {
            VStack(alignment: .leading, spacing: 8) {
                Label("Policy", systemImage: "tree")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                policyRow("ENS name", request.ensName)
                policyRow("Category", request.category)
                policyRow("Auto-buy under", request.autoUsd.usd)
                policyRow("Never above", request.maxUsd.usd)
                policyRow("Deadline", request.deadline.formatted(date: .abbreviated, time: .omitted))
            }
        }
    }

    private func policyRow(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(.footnote).foregroundStyle(Theme.textSecondary)
            Spacer()
            Text(value).font(.footnote.monospacedDigit()).foregroundStyle(Theme.textPrimary)
        }
    }
}

private struct ActivityTimeline: View {
    let activity: [ActivityEntry]
    @State private var selectedURL: URL?

    var body: some View {
        HeroCard {
            VStack(alignment: .leading, spacing: 12) {
                Label("Activity", systemImage: "clock.arrow.circlepath")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                if activity.isEmpty {
                    Text("No activity yet").font(.footnote).foregroundStyle(Theme.textSecondary)
                }
                ForEach(activity.sorted(by: { $0.date > $1.date })) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(entry.text).font(.footnote).foregroundStyle(Theme.textPrimary)
                            Spacer()
                            Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                                .font(.caption2)
                                .foregroundStyle(Theme.textSecondary)
                        }
                        if let hash = entry.txHash {
                            Button {
                                selectedURL = URL(string: "https://sepolia.etherscan.io/tx/\(hash)")
                            } label: {
                                Text(hash).font(.caption.monospaced()).foregroundStyle(Theme.accentBlue)
                            }
                        }
                    }
                    Divider().overlay(Theme.border)
                }
            }
        }
        .sheet(item: $selectedURL) { url in
            SafariView(url: url)
        }
    }
}

extension URL: @retroactive Identifiable {
    public var id: String { absoluteString }
}

/// Thin UIViewControllerRepresentable wrapper around SFSafariViewController for opening Etherscan links.
struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: url)
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}
