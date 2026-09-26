import SwiftUI
import Charts
import SafariServices

struct RequestDetailView: View {
    let request: HeroRequest
    @Environment(Store.self) private var store
    /// Settings → "Show demo controls": adds a visible Demo button for rehearsal.
    @AppStorage("hero.showDemoControls") private var showDemoControls = false
    @State private var showDemoMenu = false
    @State private var demoError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacingXL) {
                heroHeader
                priceSection
                PolicyBar(request: request)
                PriceHistoryChart(request: request)
                if let strategy = request.strategy {
                    StrategySection(strategy: strategy)
                }
                PolicySection(request: request)
                ActivityTimeline(activity: request.activity)
            }
            .padding(.horizontal, Theme.spacingM)
            .padding(.vertical, Theme.spacingL)
        }
        .background(Theme.background)
        .navigationTitle(request.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showDemoControls {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Demo") { showDemoMenu = true }
                        .font(.footnote)
                }
            }
        }
        // Hidden stage controls: long-press the price or triple-tap the title (no visible hint).
        .confirmationDialog("Demo", isPresented: $showDemoMenu, titleVisibility: .visible) {
            ForEach(DemoScenario.allCases, id: \.self) { scenario in
                Button(scenario.title, role: scenario == .reset ? .destructive : nil) { runDemo(scenario) }
            }
        }
        .sensoryFeedback(.impact(weight: .light), trigger: showDemoMenu) { _, open in open }
        .alert("Demo", isPresented: Binding(get: { demoError != nil }, set: { if !$0 { demoError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(demoError ?? "")
        }
    }

    private func runDemo(_ scenario: DemoScenario) {
        Task {
            do {
                try await store.demo(requestId: request.id, scenario: scenario)
            } catch APIError.server("not_watching") {
                demoError = "Already bought or waiting on you. Reset the request first."
            } catch {
                demoError = error.localizedDescription
            }
        }
    }

    private var heroHeader: some View {
        VStack(alignment: .leading, spacing: Theme.spacingM) {
            DetailHeroImage(imageUrl: request.imageUrl, category: request.category)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(request.title)
                            .font(.title2.bold())
                            .foregroundStyle(Theme.textPrimary)
                            .onTapGesture(count: 3) { showDemoMenu = true }
                        if let merchant = request.merchant {
                            Text(merchant)
                                .font(.subheadline)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    Spacer()
                    StatusPill(status: request.status)
                }
                Text(request.query)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var priceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(request.currentPrice.usd)
                .font(.system(size: 48, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.textPrimary)
                .contentTransition(.numericText(value: request.currentPrice))
                .onLongPressGesture(minimumDuration: 0.8) { showDemoMenu = true }
            if let target = request.targetPrice {
                deltaLine(target: target)
            }
        }
    }

    private func deltaLine(target: Double) -> some View {
        let delta = request.currentPrice - target
        let isAbove = delta > 0.5
        let isBelow = delta < -0.5
        let color: Color = isAbove ? Theme.accentAmber : (isBelow ? Theme.accentGreen : Theme.textSecondary)
        let symbol = isAbove ? "arrow.up.right" : (isBelow ? "arrow.down.right" : "minus")
        let word = isAbove ? "above" : (isBelow ? "below" : "at")
        return HStack(spacing: 6) {
            Image(systemName: symbol).font(.caption.weight(.bold))
            Text("\(abs(delta).usd) \(word) target of \(target.usd)")
                .font(.subheadline.monospacedDigit())
        }
        .foregroundStyle(color)
    }
}

/// Big rounded hero image for the detail screen — falls back to the same category glyph as
/// ``ProductThumbnail`` when there's no product photo.
private struct DetailHeroImage: View {
    let imageUrl: String?
    let category: String

    var body: some View {
        let icon = category.categoryIcon
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(icon.tint.opacity(0.12))
            if let imageUrl, let url = URL(string: imageUrl) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().scaledToFill()
                    default:
                        Image(systemName: icon.symbol)
                            .font(.system(size: 52))
                            .foregroundStyle(icon.tint)
                    }
                }
            } else {
                Image(systemName: icon.symbol)
                    .font(.system(size: 52))
                    .foregroundStyle(icon.tint)
            }
        }
        .frame(height: 220)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

/// The key visual: a single bar spanning auto-buy / needs-approval / blocked ranges, with a
/// marker showing where the current price sits.
private struct PolicyBar: View {
    let request: HeroRequest

    private var domainMax: Double {
        max(request.maxUsd, request.currentPrice) * 1.08
    }
    private var markerFraction: Double {
        min(max(request.currentPrice / domainMax, 0), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Policy")
            GeometryReader { geo in
                let width = geo.size.width
                let autoW = width * (request.autoUsd / domainMax)
                let approvalW = width * ((request.maxUsd - request.autoUsd) / domainMax)
                let markerX = (width * markerFraction).clamped(to: 24...(width - 24))

                ZStack(alignment: .leading) {
                    HStack(spacing: 2) {
                        Capsule().fill(Theme.accentGreen)
                            .frame(width: max(autoW, 4))
                        Capsule().fill(Theme.accentAmber)
                            .frame(width: max(approvalW, 4))
                        Capsule().fill(Theme.border)
                    }
                    .frame(height: 10)

                    VStack(spacing: 4) {
                        Text(request.currentPrice.usd)
                            .font(.caption2.weight(.bold).monospacedDigit())
                            .foregroundStyle(Theme.textPrimary)
                            .fixedSize()
                        Rectangle()
                            .fill(Theme.textPrimary)
                            .frame(width: 2, height: 16)
                        Circle()
                            .fill(Theme.textPrimary)
                            .frame(width: 6, height: 6)
                    }
                    .position(x: markerX, y: -6)
                }
            }
            .frame(height: 34)
            .padding(.top, 18)

            HStack {
                Text("Auto-buy ≤ \(request.autoUsd.usd)")
                Spacer()
                Text("Approval ≤ \(request.maxUsd.usd)")
            }
            .font(.caption.monospacedDigit())
            .foregroundStyle(Theme.textSecondary)
        }
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

private struct PriceHistoryChart: View {
    let request: HeroRequest
    @State private var selectedDate: Date?

    private var yLow: Double {
        let dataMin = request.priceHistory.map(\.price).min() ?? request.autoUsd
        return min(dataMin, request.autoUsd) * 0.9
    }
    private var yHigh: Double {
        let dataMax = request.priceHistory.map(\.price).max() ?? request.maxUsd
        return max(dataMax, request.maxUsd) * 1.05
    }
    private var selectedPoint: PricePoint? {
        guard let selectedDate else { return nil }
        return request.priceHistory.min { a, b in
            abs(a.date.timeIntervalSince(selectedDate)) < abs(b.date.timeIntervalSince(selectedDate))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacingS) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader(title: "Price History · 90d")
                Spacer()
                if let selectedPoint {
                    Text("\(selectedPoint.price.usd) · \(selectedPoint.date.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                }
            }

            Chart {
                RectangleMark(yStart: .value("Zero", 0), yEnd: .value("Auto", request.autoUsd))
                    .foregroundStyle(Theme.accentGreen.opacity(0.06))
                RectangleMark(yStart: .value("Auto", request.autoUsd), yEnd: .value("Max", request.maxUsd))
                    .foregroundStyle(Theme.accentAmber.opacity(0.06))

                ForEach(request.priceHistory) { point in
                    AreaMark(x: .value("Date", point.date), y: .value("Price", point.price))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Theme.accentBlue.opacity(0.16), Theme.accentBlue.opacity(0)],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                        .interpolationMethod(.catmullRom)
                    LineMark(x: .value("Date", point.date), y: .value("Price", point.price))
                        .foregroundStyle(Theme.accentBlue)
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                }

                ForEach(request.events) { event in
                    RuleMark(x: .value("Event", event.date))
                        .foregroundStyle(Theme.textSecondary.opacity(0.35))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }

                if let selectedPoint {
                    RuleMark(x: .value("Selected", selectedPoint.date))
                        .foregroundStyle(Theme.textSecondary.opacity(0.5))
                    PointMark(x: .value("Date", selectedPoint.date), y: .value("Price", selectedPoint.price))
                        .foregroundStyle(Theme.textPrimary)
                        .symbolSize(50)
                }
            }
            .chartYScale(domain: yLow...yHigh)
            .chartXSelection(value: $selectedDate)
            .chartYAxis {
                AxisMarks(position: .leading) { _ in
                    AxisGridLine().foregroundStyle(Theme.border.opacity(0.6))
                    AxisValueLabel().font(.caption2).foregroundStyle(Theme.textSecondary)
                }
            }
            .chartXAxis {
                AxisMarks { _ in
                    AxisValueLabel().font(.caption2).foregroundStyle(Theme.textSecondary)
                }
            }
            .frame(height: 180)

            if !request.events.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(request.events) { event in
                        HStack(spacing: 6) {
                            Rectangle().fill(Theme.textSecondary.opacity(0.4)).frame(width: 8, height: 1)
                            Text(event.name).font(.caption2)
                            Text("·").foregroundStyle(Theme.textSecondary.opacity(0.5))
                            Text(event.date.formatted(date: .abbreviated, time: .omitted)).font(.caption2.monospacedDigit())
                        }
                        .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        }
    }
}

private struct StrategySection: View {
    let strategy: Strategy

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacingS) {
            SectionHeader(title: "Agent Strategy")
            Text(strategy.summary)
                .font(.body)
                .foregroundStyle(Theme.textPrimary)
            VStack(alignment: .leading, spacing: 8) {
                ForEach(strategy.bullets, id: \.self) { bullet in
                    HStack(alignment: .top, spacing: 8) {
                        Circle()
                            .fill(Theme.textSecondary.opacity(0.4))
                            .frame(width: 4, height: 4)
                            .padding(.top, 6)
                        Text(bullet)
                            .font(.subheadline)
                            .foregroundStyle(Theme.textSecondary)
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
            .padding(.top, 2)
        }
    }
}

private struct PolicySection: View {
    let request: HeroRequest

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacingS) {
            SectionHeader(title: "ENS Policy")
            Text(request.ensName)
                .font(.subheadline.monospaced())
                .foregroundStyle(Theme.textPrimary)
            VStack(spacing: 0) {
                policyRow("Category", request.category)
                HairlineDivider()
                policyRow("Auto-buy under", request.autoUsd.usd)
                HairlineDivider()
                policyRow("Never above", request.maxUsd.usd)
                HairlineDivider()
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
        .padding(.vertical, 9)
    }
}

private struct ActivityTimeline: View {
    let activity: [ActivityEntry]
    @State private var selectedURL: URL?

    private var sorted: [ActivityEntry] { activity.sorted { $0.date > $1.date } }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacingS) {
            SectionHeader(title: "Activity")
            if activity.isEmpty {
                Text("No activity yet").font(.footnote).foregroundStyle(Theme.textSecondary)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(sorted.enumerated()), id: \.element.id) { index, entry in
                        HStack(alignment: .top, spacing: 12) {
                            VStack(spacing: 0) {
                                Circle().fill(entry.blocked == true ? Theme.accentRed : Theme.accentBlue).frame(width: 6, height: 6).padding(.top, 5)
                                if index < sorted.count - 1 {
                                    Rectangle().fill(Theme.border).frame(width: 1).frame(maxHeight: .infinity)
                                }
                            }
                            .frame(width: 6)

                            VStack(alignment: .leading, spacing: 3) {
                                if entry.blocked == true {
                                    Label(entry.text, systemImage: "xmark.shield.fill")
                                        .font(.footnote.weight(.medium))
                                        .foregroundStyle(Theme.accentRed)
                                } else {
                                    Text(entry.text).font(.footnote).foregroundStyle(Theme.textPrimary)
                                }
                                HStack(spacing: 8) {
                                    Text(entry.date.formatted(date: .abbreviated, time: .shortened))
                                        .font(.caption2)
                                        .foregroundStyle(Theme.textSecondary)
                                    if let hash = entry.txHash {
                                        Button {
                                            selectedURL = URL(string: "https://sepolia.etherscan.io/tx/\(hash)")
                                        } label: {
                                            Text(shortHash(hash)).font(.caption2.monospaced())
                                        }
                                        .foregroundStyle(Theme.accentBlue)
                                    }
                                }
                            }
                            .padding(.bottom, 14)
                        }
                    }
                }
            }
        }
        .sheet(item: $selectedURL) { url in
            SafariView(url: url)
        }
    }

    private func shortHash(_ hash: String) -> String {
        guard hash.count > 12 else { return hash }
        return "\(hash.prefix(8))...\(hash.suffix(6))"
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
