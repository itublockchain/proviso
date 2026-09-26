import SwiftUI

struct BudgetsView: View {
    @Environment(Store.self) private var store
    @State private var editingCategory: Category?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    if let wallet = store.budgets?.wallet {
                        WalletHeaderCard(wallet: wallet)
                    }
                    ForEach(store.budgets?.categories ?? []) { category in
                        Button {
                            editingCategory = category
                        } label: {
                            CategoryCard(category: category)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
            .background(Theme.background)
            .navigationTitle("Budgets")
            .refreshable { await store.loadAll() }
            .sheet(item: $editingCategory) { category in
                EditCategorySheet(category: category)
            }
        }
    }
}

private struct WalletHeaderCard: View {
    let wallet: Wallet

    var body: some View {
        HeroCard {
            VStack(alignment: .leading, spacing: 10) {
                Label(wallet.ensRoot, systemImage: "person.crop.circle")
                    .font(.headline)
                    .foregroundStyle(Theme.textPrimary)
                Text(short(wallet.address))
                    .font(.caption.monospaced())
                    .foregroundStyle(Theme.textSecondary)
                Divider().overlay(Theme.border)
                HStack {
                    stat("USDC Balance", wallet.usdcBalance.usd)
                    Spacer()
                    stat("Allowance", wallet.allowance.usd)
                }
                stat("Agent", short(wallet.agent))
                Divider().overlay(Theme.border)
                WorldIDLinkRow(worldLinked: wallet.worldLinked ?? false)
            }
        }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(Theme.textSecondary)
            Text(value).font(.subheadline.monospaced()).foregroundStyle(Theme.textPrimary)
        }
    }

    private func short(_ address: String) -> String {
        guard address.count > 10 else { return address }
        return "\(address.prefix(6))...\(address.suffix(4))"
    }
}

private struct CategoryCard: View {
    let category: Category

    private var progress: Double {
        guard category.limitUsd > 0 else { return 0 }
        return min(category.spentUsd / category.limitUsd, 1)
    }

    var body: some View {
        HeroCard {
            HStack(spacing: 16) {
                ZStack {
                    Circle()
                        .stroke(Theme.border, lineWidth: 6)
                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(progress > 0.9 ? Theme.accentAmber : Theme.accentGreen, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text("\(Int(progress * 100))%")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(Theme.textPrimary)
                        .contentTransition(.numericText())
                }
                .frame(width: 56, height: 56)
                .animation(.spring(duration: 0.5), value: progress)

                VStack(alignment: .leading, spacing: 4) {
                    Text(category.name).font(.headline).foregroundStyle(Theme.textPrimary)
                    Text(category.ensName).font(.caption).foregroundStyle(Theme.textSecondary)
                    Text("\(category.spentUsd.usd) of \(category.limitUsd.usd) spent")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                    Text("Resets \(category.periodEnds.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary.opacity(0.8))
                }
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(Theme.textSecondary)
            }
        }
    }
}

private struct EditCategorySheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let category: Category
    @State private var limitUsd: Double
    @State private var usePercent: Bool
    @State private var pct: Double

    init(category: Category) {
        self.category = category
        _limitUsd = State(initialValue: category.limitUsd)
        _usePercent = State(initialValue: category.pct != nil)
        _pct = State(initialValue: (category.pct ?? 0.1) * 100)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(category.ensName) {
                    HStack {
                        Text("Monthly limit")
                        Spacer()
                        TextField("Limit", value: $limitUsd, format: .currency(code: "USD"))
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 120)
                    }
                    Toggle("Also cap as % of balance", isOn: $usePercent)
                    if usePercent {
                        HStack {
                            Text("Percent")
                            Spacer()
                            Text("\(Int(pct))%").foregroundStyle(Theme.textSecondary)
                        }
                        Slider(value: $pct, in: 1...100, step: 1)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Edit \(category.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task {
                            try? await store.updateBudget(name: category.name, limitUsd: limitUsd, pct: usePercent ? pct / 100 : nil)
                            dismiss()
                        }
                    }
                }
            }
        }
    }
}
