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

    /// The freshest copy of this request — the Store may have a newer one from polling.
    private var current: HeroRequest { store.request(id: request.id) ?? request }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.spacingXL) {
                    heroHeader
                    if current.preparing != nil || current.setupError != nil {
                        SetupCard(request: current)
                    }
                    if let order = current.order {
                        OrderSection(order: order, request: current)
                            .id("order")
                    }
                    if current.preparing == nil { priceSection } // no live price yet while stores are compared
                    PolicyBar(request: current)
                    if let offers = current.offers, !offers.isEmpty {
                        StoresSection(offers: offers)
                            .id("stores")
                    }
                    if !current.priceHistory.isEmpty { PriceHistoryChart(request: current) }
                    if let strategy = current.strategy {
                        StrategySection(strategy: strategy)
                    }
                    PolicySection(request: current)
                    ActivityTimeline(activity: current.activity)
                }
                .padding(.horizontal, Theme.spacingM)
                .padding(.vertical, Theme.spacingL)
            }
            // QA-only: jump straight to the order's timeline for scripted screenshots.
            .task {
                let args = ProcessInfo.processInfo.arguments
                guard args.contains("-uiTestScrollOrderBottom") || args.contains("-uiTestScrollStores") else { return }
                try? await Task.sleep(for: .milliseconds(400))
                withAnimation {
                    if args.contains("-uiTestScrollStores") { proxy.scrollTo("stores", anchor: .bottom) }
                    else { proxy.scrollTo("order", anchor: .bottom) }
                }
            }
        }
        .background(Theme.background)
        .navigationTitle(current.title)
        .navigationBarTitleDisplayMode(.inline)
        // Poll while the screen is visible and something is still moving: the background setup, or the order until delivered.
        .task(id: request.id) {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(current.preparing != nil ? 1.5 : 3))
                if Task.isCancelled { return }
                await store.refreshRequest(id: request.id)
                let orderMoving = current.order != nil && current.order?.status != "delivered"
                if current.preparing == nil && !orderMoving { return }
            }
        }
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
            } catch APIError.server("no_listing") {
                demoError = "No live store listing to re-check for this request."
            } catch {
                demoError = error.localizedDescription
            }
        }
    }

    private var heroHeader: some View {
        VStack(alignment: .leading, spacing: Theme.spacingM) {
            DetailHeroImage(imageUrl: current.imageUrl, category: current.category)
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(current.title)
                            .font(.title2.bold())
                            .foregroundStyle(Theme.textPrimary)
                            .onTapGesture(count: 3) { showDemoMenu = true }
                        if let merchant = current.merchant {
                            Text(merchant)
                                .font(.subheadline)
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    Spacer()
                    StatusPill(status: current.status)
                }
                Text(current.query)
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private var priceSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(current.currentPrice.usd)
                .font(.system(size: 48, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(Theme.textPrimary)
                .contentTransition(.numericText(value: current.currentPrice))
                .onLongPressGesture(minimumDuration: 0.8) { showDemoMenu = true }
            if let target = current.targetPrice {
                deltaLine(target: target)
            }
            if let list = current.listPrice, list > current.currentPrice {
                Text("List \(list.usd) · \(Int(((1 - current.currentPrice / list) * 100).rounded()))% below")
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func deltaLine(target: Double) -> some View {
        let delta = current.currentPrice - target
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
        // The fill image lives in an overlay so its natural width can never widen the page.
        RoundedRectangle(cornerRadius: 24, style: .continuous)
            .fill(icon.tint.opacity(0.12))
            .frame(maxWidth: .infinity)
            .frame(height: 220)
            .overlay {
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
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

/// Shown right under the header once an order exists: what was bought, from whom, how it was
/// approved, the on-chain payment, and a simulated merchant fulfillment timeline.
private struct OrderSection: View {
    let order: MerchantOrder
    let request: HeroRequest
    @Environment(Store.self) private var store
    @State private var safariURL: URL?

    private var receiptURL: URL? {
        URL(string: store.backendURLString)?.appendingPathComponent("merchant/orders/\(order.id)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacingS) {
            HStack {
                SectionHeader(title: "Order \(order.id)")
                Spacer()
                Text("SIMULATED MERCHANT")
                    .font(.caption2.weight(.semibold))
                    .kerning(0.4)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.accentAmber.opacity(0.16))
                    .foregroundStyle(Theme.accentAmber)
                    .clipShape(Capsule())
            }

            itemRow

            VStack(spacing: 0) {
                row("Merchant") {
                    Text(order.merchantVerified ? "\(order.merchantName) ✓ \(order.registry)" : order.merchantName)
                }
                HairlineDivider()
                row("Approval") {
                    Text(order.humanApproved ? "Approved by you with World ID" : "Bought on its own (under \(request.autoUsd.usd))")
                }
                HairlineDivider()
                row("Payment") {
                    if let txHash = order.txHash {
                        Button { safariURL = URL(string: "https://sepolia.etherscan.io/tx/\(txHash)") } label: {
                            Text(txHash.shortAddress).font(.footnote.monospaced())
                        }
                        .foregroundStyle(Theme.accentBlue)
                    } else {
                        Text("—")
                    }
                }
            }

            OrderTimelineView(steps: order.timeline)

            VStack(alignment: .leading, spacing: Theme.spacingXS) {
                Text("Signed by \(order.merchantAddress.shortAddress) · listed in \(order.registry)")
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                HStack(spacing: Theme.spacingM) {
                    if let receiptURL {
                        Button("View signed receipt") { safariURL = receiptURL }
                    }
                    if let storeUrl = order.storeUrl, let url = URL(string: storeUrl) {
                        Button("Visit store") { safariURL = url }
                    }
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.accentBlue)
            }
            .padding(.top, 4)

            Text("Payment and your rules are real (Ethereum Sepolia). Store checkout and shipping are simulated by Proviso's demo merchant — 7 days compressed to 45 seconds.")
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 2)
        }
        .sheet(item: $safariURL) { url in
            SafariView(url: url)
        }
    }

    private var itemRow: some View {
        HStack(spacing: 12) {
            ProductThumbnail(imageUrl: order.imageUrl ?? request.imageUrl, category: request.category, size: 48)
            VStack(alignment: .leading, spacing: 2) {
                Text(order.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                if let store = order.store {
                    Text("Listing from \(store)").font(.caption).foregroundStyle(Theme.textSecondary)
                }
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(order.priceUsd.usd).font(.subheadline.weight(.semibold).monospacedDigit()).foregroundStyle(Theme.textPrimary)
                if let listPrice = order.listPriceUsd, listPrice > order.priceUsd {
                    Text(listPrice.usd).font(.caption2.monospacedDigit()).strikethrough().foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func row(_ label: String, @ViewBuilder value: () -> some View) -> some View {
        HStack {
            Text(label).font(.footnote).foregroundStyle(Theme.textSecondary)
            Spacer()
            value().font(.footnote).foregroundStyle(Theme.textPrimary)
        }
        .padding(.vertical, 9)
    }
}

/// Vertical 4-step fulfillment timeline: filled dots for done steps, hollow for pending, with a
/// subtle animation when a step flips to done (driven by polling in RequestDetailView).
private struct OrderTimelineView: View {
    let steps: [OrderStep]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                HStack(alignment: .top, spacing: 12) {
                    VStack(spacing: 0) {
                        Circle()
                            .fill(step.done ? Theme.accentGreen : Theme.background)
                            .overlay(Circle().stroke(step.done ? Theme.accentGreen : Theme.border, lineWidth: 1.5))
                            .frame(width: 8, height: 8)
                            .padding(.top, 4)
                            .animation(.easeInOut(duration: 0.35), value: step.done)
                        if index < steps.count - 1 {
                            Rectangle().fill(Theme.border).frame(width: 1).frame(maxHeight: .infinity)
                        }
                    }
                    .frame(width: 8)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.label)
                            .font(.footnote.weight(step.done ? .semibold : .regular))
                            .foregroundStyle(step.done ? Theme.textPrimary : Theme.textSecondary)
                        if step.done {
                            Text(step.at.formatted(date: .omitted, time: .shortened))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .padding(.bottom, 14)
                }
            }
        }
        .padding(.top, 8)
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
                SectionHeader(title: request.historyModeled == true ? "Price History (modeled) · 90d" : "Price History · 90d")
                Spacer()
                if let selectedPoint {
                    Text("\(selectedPoint.price.usd) · \(selectedPoint.date.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                }
            }

            Chart {
                RectangleMark(yStart: .value("Low", yLow), yEnd: .value("Auto", request.autoUsd))
                    .foregroundStyle(Theme.accentGreen.opacity(0.06))
                RectangleMark(yStart: .value("Auto", request.autoUsd), yEnd: .value("Max", request.maxUsd))
                    .foregroundStyle(Theme.accentAmber.opacity(0.06))

                ForEach(request.priceHistory) { point in
                    AreaMark(x: .value("Date", point.date), yStart: .value("Low", yLow), yEnd: .value("Price", point.price))
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
            .chartPlotStyle { $0.clipped() } // bands and area stay inside the plot, never over the text below
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

            if request.historyModeled == true {
                Text("Modeled around today's live price and past sale dates, not observed prices.")
                    .font(.caption2)
                    .foregroundStyle(Theme.textSecondary)
            }

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

/// Live prices for this product at every store Proviso compared (Monid: Google Shopping + Amazon), cheapest first.
/// Tapping a row opens the store's listing; Proviso never checks out there.
private struct StoresSection: View {
    let offers: [StoreOffer]
    @State private var safariURL: URL?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacingS) {
            HStack(alignment: .firstTextBaseline) {
                SectionHeader(title: "Compared \(offers.count) \(offers.count == 1 ? "store" : "stores")")
                Spacer()
                Text("live via Monid").font(.caption).foregroundStyle(Theme.textSecondary)
            }
            VStack(spacing: 0) {
                ForEach(Array(offers.enumerated()), id: \.element.id) { index, offer in
                    if index > 0 { HairlineDivider() }
                    Button { safariURL = URL(string: offer.url) } label: { row(offer, cheapest: index == 0) }
                        .buttonStyle(.plain)
                }
            }
        }
        .sheet(item: $safariURL) { url in
            SafariView(url: url)
        }
    }

    private func row(_ offer: StoreOffer, cheapest: Bool) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(offer.store).font(.subheadline.weight(.medium)).foregroundStyle(Theme.textPrimary).lineLimit(1)
                HStack(spacing: 6) {
                    Text(offer.source == "amazon" ? "Amazon" : "Google Shopping")
                    if let rating = offer.rating {
                        Text("★ \(String(format: "%.1f", rating))")
                    }
                }
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
            }
            Spacer()
            if cheapest {
                Text("CHEAPEST")
                    .font(.caption2.weight(.semibold))
                    .kerning(0.4)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Theme.accentGreen.opacity(0.16))
                    .foregroundStyle(Theme.accentGreen)
                    .clipShape(Capsule())
            }
            Text(offer.price.formatted(.currency(code: "USD").locale(Locale(identifier: "en_US"))))
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
            Image(systemName: "arrow.up.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens the store's listing")
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
            Link(destination: URL(string: "https://explorer.ens.dev/\(request.ensName)") ?? URL(string: "https://explorer.ens.dev")!) {
                HStack(spacing: 4) {
                    Text(request.ensName)
                        .font(.subheadline.monospaced())
                        .foregroundStyle(Theme.textPrimary)
                    Image(systemName: "arrow.up.right").font(.caption2)
                }
            }
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

/// Right after "Save rules": the backend is still comparing stores, writing the rules to ENS and planning.
/// Shows the running step, and the reason in plain words if setup stopped.
private struct SetupCard: View {
    let request: HeroRequest
    private static let steps = ["Comparing stores", "Writing your rules to ENS", "Planning when to buy"]

    var body: some View {
        HeroCard {
            VStack(alignment: .leading, spacing: Theme.spacingS) {
                if let error = request.setupError {
                    Label("Setup stopped", systemImage: "exclamationmark.triangle.fill")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.accentRed)
                    Text(error)
                        .font(.footnote)
                        .foregroundStyle(Theme.textPrimary)
                        .textSelection(.enabled)
                } else {
                    let now = Self.steps.firstIndex(of: request.preparing ?? "") ?? 0
                    ForEach(Array(Self.steps.enumerated()), id: \.offset) { i, step in
                        HStack(spacing: 10) {
                            Group {
                                if i < now { Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accentGreen) }
                                else if i == now { ProgressView().controlSize(.small) }
                                else { Image(systemName: "circle").foregroundStyle(Theme.textSecondary.opacity(0.5)) }
                            }
                            .frame(width: 18)
                            Text(step)
                                .font(.subheadline)
                                .foregroundStyle(i <= now ? Theme.textPrimary : Theme.textSecondary)
                        }
                    }
                    .animation(.snappy, value: request.preparing)
                }
                // step-level problems (a failed store search, a reverted tx) are in the activity feed, in red
                if let problem = request.activity.last(where: { $0.blocked == true }), request.setupError == nil {
                    Text(problem.text)
                        .font(.footnote)
                        .foregroundStyle(Theme.accentRed)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
