import SwiftUI

struct BudgetsView: View {
    @Environment(Store.self) private var store
    @State private var editingCategory: Category?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.spacingXL) {
                    if let wallet = store.budgets?.wallet {
                        WalletHeader(wallet: wallet)
                    }
                    if let categories = store.budgets?.categories, !categories.isEmpty {
                        VStack(alignment: .leading, spacing: Theme.spacingS) {
                            SectionHeader(title: "Categories")
                            VStack(spacing: 0) {
                                ForEach(categories) { category in
                                    Button {
                                        editingCategory = category
                                    } label: {
                                        CategoryRow(category: category)
                                    }
                                    .buttonStyle(.plain)
                                    if category.id != categories.last?.id {
                                        HairlineDivider()
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, Theme.spacingM)
                .padding(.vertical, Theme.spacingL)
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

private struct WalletHeader: View {
    let wallet: Wallet

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.spacingM) {
            VStack(alignment: .leading, spacing: 4) {
                Text(wallet.ensRoot).font(.title2.bold()).foregroundStyle(Theme.textPrimary)
                Text(short(wallet.address)).font(.caption.monospaced()).foregroundStyle(Theme.textSecondary)
            }
            HStack(spacing: Theme.spacingXL) {
                stat("USDC Balance", wallet.usdcBalance.usd)
                stat("Allowance", wallet.allowance.usd)
            }
            HairlineDivider()
            stat("Agent", short(wallet.agent))
            HairlineDivider()
            WorldIDLinkRow(worldLinked: wallet.worldLinked ?? false)
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

private struct CategoryRow: View {
    let category: Category

    private var progress: Double {
        guard category.limitUsd > 0 else { return 0 }
        return min(category.spentUsd / category.limitUsd, 1)
    }

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(category.name).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text("\(category.spentUsd.usd) of \(category.limitUsd.usd)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(Theme.textSecondary)
                }

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.border)
                        Capsule()
                            .fill(progress > 0.9 ? Theme.accentAmber : Theme.accentGreen)
                            .frame(width: geo.size.width * progress)
                            .animation(.spring(duration: 0.5), value: progress)
                    }
                }
                .frame(height: 4)

                HStack {
                    Text(category.ensName).font(.caption2.monospaced()).foregroundStyle(Theme.textSecondary)
                    Spacer()
                    Text("Resets \(category.periodEnds.formatted(date: .abbreviated, time: .omitted))")
                        .font(.caption2)
                        .foregroundStyle(Theme.textSecondary.opacity(0.8))
                }
            }
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.textSecondary.opacity(0.5))
        }
        .padding(.vertical, 12)
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
