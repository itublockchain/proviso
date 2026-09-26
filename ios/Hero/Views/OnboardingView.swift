import SwiftUI

private struct OnboardingContent {
    let title: String
    let subtitle: String
}

private let onboardingPages: [OnboardingContent] = [
    .init(title: "Proviso", subtitle: "Your shopping agent. Your wallet. Your rules."),
    .init(title: "Just say what you want.", subtitle: "A Sony TV before next month, never above $500. Proviso takes it from there."),
    .init(title: "It waits for the right moment.", subtitle: "Proviso watches prices and upcoming sales, and buys when the price is right — not when you happen to ask."),
    .init(title: "Your money never leaves your wallet.", subtitle: "No deposits, no agent wallet. Proviso can only spend what your rules allow, straight from your own wallet."),
    .init(title: "Rules that live on your name.", subtitle: "Buy on your own under $400. Ask me up to $500. Never above that. Your rules are saved on your ENS name, where any app — and the payment contract — can read them."),
    .init(title: "Budgets that take care of themselves.", subtitle: "Give hobbies $1,000 a month. Every request shares it, and it resets on its own."),
    .init(title: "You approve what matters.", subtitle: "Above your limit, Proviso asks you — and only you — to confirm with World ID, right in the moment."),
    .init(title: "Tricks don't work.", subtitle: "Even if a website tries to fool the agent, the rules are enforced by the payment contract itself. Wrong shop, wrong price, over budget: it simply can't pay."),
]

/// First-launch, presentation-grade walkthrough. Replayable from Settings. Ends in the mandatory
/// World ID sign-in, then an optional budgets step, then the app itself.
struct OnboardingView: View {
    @Environment(Store.self) private var store
    @State private var page = 0
    @State private var showBudgetsSetup = false

    private var signInPageIndex: Int { onboardingPages.count }

    var body: some View {
        if showBudgetsSetup {
            BudgetsSetupView { store.onboardingSeen = true }
                .transition(.opacity)
        } else {
            ZStack {
                Theme.background.ignoresSafeArea()

                TabView(selection: $page) {
                    ForEach(onboardingPages.indices, id: \.self) { index in
                        OnboardingPageView(content: onboardingPages[index], index: index)
                            .tag(index)
                    }
                    SignInPanel { showBudgetsSetup = true }
                        .tag(signInPageIndex)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))

                VStack {
                    HStack {
                        PageDots(count: onboardingPages.count + 1, current: page)
                        Spacer()
                        if page < signInPageIndex {
                            Button("Skip") {
                                withAnimation(.spring(duration: 0.35)) { page = signInPageIndex }
                            }
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.textSecondary)
                        }
                    }
                    .padding(.horizontal, Theme.spacingM)
                    .padding(.top, Theme.spacingS)

                    Spacer()

                    if page < signInPageIndex {
                        Button {
                            withAnimation(.spring(duration: 0.35)) { page += 1 }
                        } label: {
                            Text("Continue")
                                .foregroundStyle(Theme.background)
                                .frame(maxWidth: .infinity)
                                .fontWeight(.semibold)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.textPrimary)
                        .padding(.horizontal, Theme.spacingL)
                        .padding(.bottom, Theme.spacingXL)
                    }
                }
            }
        }
    }
}

private struct PageDots: View {
    let count: Int
    let current: Int

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { i in
                Capsule()
                    .fill(i == current ? Theme.textPrimary : Theme.border)
                    .frame(width: i == current ? 16 : 6, height: 6)
            }
        }
        .animation(.spring(duration: 0.3), value: current)
    }
}

/// One idea per page: big title, one line of copy, a small animated illustration above.
private struct OnboardingPageView: View {
    let content: OnboardingContent
    let index: Int
    @State private var appeared = false

    var body: some View {
        VStack(spacing: Theme.spacingXL) {
            Spacer()
            IllustrationStage(index: index, appeared: appeared)
                .frame(height: 200)
            VStack(spacing: Theme.spacingS) {
                Text(content.title)
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center)
                Text(content.subtitle)
                    .font(.body)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Theme.spacingL)
            }
            Spacer()
            Spacer()
        }
        .padding(.horizontal, Theme.spacingL)
        .opacity(appeared ? 1 : 0)
        .onAppear { withAnimation(.spring(duration: 0.5)) { appeared = true } }
        .onDisappear { appeared = false }
    }
}

/// Small capsule label reused across illustrations for policy/deadline/sale tags.
private struct OnboardingChip: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Theme.secondaryBackground)
            .foregroundStyle(Theme.textSecondary)
            .clipShape(Capsule())
    }
}

private struct IllustrationStage: View {
    let index: Int
    let appeared: Bool

    var body: some View {
        switch index {
        case 0: HeroMarkIllustration(appeared: appeared)
        case 1: ChatIllustration(appeared: appeared)
        case 2: PriceChartIllustration(appeared: appeared)
        case 3: WalletLockIllustration(appeared: appeared)
        case 4: PolicyChipIllustration(appeared: appeared)
        case 5: BudgetFillIllustration(appeared: appeared)
        case 6: ApprovalCodeIllustration(appeared: appeared)
        default: ShieldDeflectIllustration(appeared: appeared)
        }
    }
}

// MARK: - Page 1: Proviso mark

private struct HeroMarkIllustration: View {
    let appeared: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(Theme.accentBlue.opacity(0.18))
                .frame(width: 160, height: 160)
                .blur(radius: 30)
            Image(systemName: "sparkles")
                .font(.system(size: 72, weight: .semibold))
                .foregroundStyle(Theme.accentBlue)
                .symbolEffect(.bounce, value: appeared)
        }
        .scaleEffect(appeared ? 1 : 0.6)
        .animation(.spring(duration: 0.6), value: appeared)
    }
}

// MARK: - Page 2: chat typing + chips

private struct ChatIllustration: View {
    let appeared: Bool
    private let sentence = "A Sony TV, never above $500."
    @State private var typed = ""
    @State private var showChips = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacingS) {
            Text(typed.isEmpty ? " " : typed)
                .font(.subheadline)
                .foregroundStyle(Theme.textPrimary)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Theme.secondaryBackground)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .frame(minHeight: 40, alignment: .leading)
            if showChips {
                HStack(spacing: 6) {
                    OnboardingChip("Deadline")
                    OnboardingChip("$400 auto")
                    OnboardingChip("$500 max")
                }
                .transition(.opacity.combined(with: .move(edge: .leading)))
            }
        }
        .onChange(of: appeared) { _, new in if new { type() } }
    }

    private func type() {
        typed = ""
        showChips = false
        Task {
            for char in sentence {
                typed.append(char)
                try? await Task.sleep(for: .milliseconds(28))
            }
            withAnimation(.spring(duration: 0.4)) { showChips = true }
        }
    }
}

// MARK: - Page 3: price line drawing itself

private struct PriceChartIllustration: View {
    let appeared: Bool
    @State private var progress: CGFloat = 0
    @State private var showMarker = false
    private let points: [CGFloat] = [0.8, 0.7, 0.75, 0.5, 0.2, 0.35, 0.6]
    private let dipIndex = 4

    var body: some View {
        VStack(spacing: Theme.spacingS) {
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                let step = w / CGFloat(points.count - 1)
                ZStack(alignment: .topLeading) {
                    Path { path in
                        for (i, p) in points.enumerated() {
                            let pt = CGPoint(x: step * CGFloat(i), y: h * p)
                            if i == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                        }
                    }
                    .trim(from: 0, to: progress)
                    .stroke(Theme.accentBlue, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))

                    if showMarker {
                        VStack(spacing: 2) {
                            Text("Buy here").font(.caption2.weight(.bold)).foregroundStyle(Theme.accentGreen)
                            Circle().fill(Theme.accentGreen).frame(width: 8, height: 8)
                        }
                        .position(x: step * CGFloat(dipIndex), y: max(h * points[dipIndex] - 14, 14))
                        .transition(.scale.combined(with: .opacity))
                    }
                }
            }
            .frame(height: 110)
            HStack(spacing: 6) {
                OnboardingChip("11.11")
                OnboardingChip("Black Friday")
            }
        }
        .onChange(of: appeared) { _, new in if new { draw() } }
    }

    private func draw() {
        progress = 0
        showMarker = false
        withAnimation(.easeInOut(duration: 1.1)) { progress = 1 }
        Task {
            try? await Task.sleep(for: .milliseconds(1150))
            withAnimation(.spring(duration: 0.4)) { showMarker = true }
        }
    }
}

// MARK: - Page 4: wallet -> allowance -> lock

private struct WalletLockIllustration: View {
    let appeared: Bool
    @State private var lineProgress: CGFloat = 0
    @State private var locked = false

    var body: some View {
        VStack(spacing: Theme.spacingM) {
            HStack(spacing: 0) {
                Image(systemName: "wallet.bifold.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Theme.accentBlue)
                GeometryReader { geo in
                    Path { path in
                        path.move(to: CGPoint(x: 0, y: geo.size.height / 2))
                        path.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height / 2))
                    }
                    .trim(from: 0, to: lineProgress)
                    .stroke(Theme.textSecondary, style: StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                }
                .frame(height: 44)
                Image(systemName: locked ? "lock.fill" : "lock.open.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(Theme.accentGreen)
                    .symbolEffect(.bounce, value: locked)
            }
            Text("Allowance only").font(.caption).foregroundStyle(Theme.textSecondary)
        }
        .onChange(of: appeared) { _, new in if new { animate() } }
    }

    private func animate() {
        lineProgress = 0
        locked = false
        withAnimation(.easeInOut(duration: 0.8)) { lineProgress = 1 }
        Task {
            try? await Task.sleep(for: .milliseconds(800))
            locked = true
        }
    }
}

// MARK: - Page 5: policy bar + ENS name chip

private struct PolicyChipIllustration: View {
    let appeared: Bool

    var body: some View {
        VStack(spacing: Theme.spacingM) {
            HStack(spacing: 3) {
                Capsule().fill(Theme.accentGreen).frame(width: 110, height: 10)
                Capsule().fill(Theme.accentAmber).frame(width: 80, height: 10)
                Capsule().fill(Theme.border).frame(width: 50, height: 10)
            }
            HStack(spacing: 14) {
                StatusDot(color: Theme.accentGreen, label: "Auto")
                StatusDot(color: Theme.accentAmber, label: "Ask")
                StatusDot(color: Theme.textSecondary, label: "Never")
            }
            OnboardingChip("ps5.hobby.herodemo.eth")
        }
        .scaleEffect(appeared ? 1 : 0.85)
        .opacity(appeared ? 1 : 0)
        .animation(.spring(duration: 0.5), value: appeared)
    }
}

// MARK: - Page 6: budget bar filling

private struct BudgetFillIllustration: View {
    let appeared: Bool
    @State private var fill: CGFloat = 0

    var body: some View {
        VStack(spacing: Theme.spacingM) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.border)
                    Capsule().fill(Theme.accentGreen).frame(width: geo.size.width * fill)
                }
            }
            .frame(width: 220, height: 14)
            HStack {
                Text("Hobby").font(.caption.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                Spacer()
                Text("resets in 12 days").font(.caption2).foregroundStyle(Theme.textSecondary)
            }
            .frame(width: 220)
        }
        .onChange(of: appeared) { _, new in
            if new { withAnimation(.spring(duration: 0.9)) { fill = 0.68 } }
        }
    }
}

// MARK: - Page 7: approval code + confirm

private struct ApprovalCodeIllustration: View {
    let appeared: Bool
    @State private var confirmed = false

    var body: some View {
        VStack(spacing: Theme.spacingM) {
            Text("WRLD-7F2A")
                .font(.system(size: 28, weight: .bold, design: .monospaced))
                .kerning(3)
                .foregroundStyle(Theme.textPrimary)
            ZStack {
                Circle().fill(Theme.accentGreen.opacity(confirmed ? 0.16 : 0)).frame(width: 64, height: 64)
                Image(systemName: confirmed ? "checkmark.circle.fill" : "circle.dotted")
                    .font(.system(size: 40))
                    .foregroundStyle(confirmed ? Theme.accentGreen : Theme.textSecondary)
                    .symbolEffect(.bounce, value: confirmed)
            }
        }
        .onChange(of: appeared) { _, new in
            if new {
                confirmed = false
                Task {
                    try? await Task.sleep(for: .milliseconds(700))
                    withAnimation(.spring(duration: 0.4)) { confirmed = true }
                }
            }
        }
    }
}

// MARK: - Page 8: shield deflects a spoofed payTo

private struct ShieldDeflectIllustration: View {
    let appeared: Bool
    @State private var chipOffset: CGFloat = -90
    @State private var deflected = false

    var body: some View {
        ZStack {
            Image(systemName: "shield.fill")
                .font(.system(size: 72))
                .foregroundStyle(Theme.accentBlue)
                .symbolEffect(.bounce, value: deflected)
            Text("payTo swapped")
                .font(.caption2.weight(.bold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Theme.accentRed)
                .foregroundStyle(.white)
                .clipShape(Capsule())
                .offset(x: chipOffset, y: deflected ? -36 : 0)
                .rotationEffect(.degrees(deflected ? -18 : 0))
        }
        .onChange(of: appeared) { _, new in if new { animate() } }
    }

    private func animate() {
        chipOffset = -90
        deflected = false
        withAnimation(.easeIn(duration: 0.5)) { chipOffset = -4 }
        Task {
            try? await Task.sleep(for: .milliseconds(520))
            withAnimation(.spring(duration: 0.45)) {
                deflected = true
                chipOffset = 70
            }
        }
    }
}

// MARK: - Optional post-sign-in step

/// "Set your monthly budgets" — optional, shown once right after the first sign-in.
private struct BudgetsSetupView: View {
    @Environment(Store.self) private var store
    let onDone: () -> Void
    @State private var hobby: Double = 1000
    @State private var needs: Double = 3000
    @State private var saving = false

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: Theme.spacingS) {
                Text("Set your monthly budgets")
                    .font(.system(size: 28, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center)
                Text("Optional — you can always change these later in Budgets.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, Theme.spacingL)

            VStack(spacing: Theme.spacingL) {
                budgetRow(title: "Hobby", value: $hobby)
                HairlineDivider()
                budgetRow(title: "Needs", value: $needs)
            }
            .padding(.horizontal, Theme.spacingL)
            .padding(.top, Theme.spacingXL)

            Spacer()

            VStack(spacing: Theme.spacingS) {
                Button {
                    Task { await save() }
                } label: {
                    Text(saving ? "Saving…" : "Done")
                        .foregroundStyle(Theme.background)
                        .frame(maxWidth: .infinity)
                        .fontWeight(.semibold)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.textPrimary)
                .disabled(saving)

                Button("Skip for now") { onDone() }
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .disabled(saving)
            }
            .padding(.horizontal, Theme.spacingL)
            .padding(.bottom, Theme.spacingXL)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
    }

    private func budgetRow(title: String, value: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: Theme.spacingS) {
            HStack {
                Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                Spacer()
                Text(value.wrappedValue.usd)
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(Theme.textSecondary)
                    .contentTransition(.numericText())
            }
            Slider(value: value, in: 100...5000, step: 50)
                .tint(Theme.accentGreen)
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        try? await store.updateBudget(name: "Hobby", limitUsd: hobby, pct: nil)
        try? await store.updateBudget(name: "Needs", limitUsd: needs, pct: nil)
        onDone()
    }
}
