import SwiftUI

struct SettingsView: View {
    @Environment(Store.self) private var store

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.spacingXL) {
                    backendSection
                    if let wallet = store.budgets?.wallet {
                        walletSection(wallet)
                    }
                    aboutSection
                }
                .padding(.horizontal, Theme.spacingM)
                .padding(.vertical, Theme.spacingL)
            }
            .background(Theme.background)
            .navigationTitle("Settings")
        }
    }

    private var backendSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Backend").padding(.bottom, Theme.spacingS)
            HairlineDivider()
            Toggle("Demo mode (mock data)", isOn: Binding(
                get: { store.demoMode },
                set: { store.demoMode = $0 }
            ))
            .padding(.vertical, 9)
            if !store.demoMode {
                HairlineDivider()
                TextField("Backend URL", text: Binding(
                    get: { store.backendURLString },
                    set: { store.backendURLString = $0 }
                ))
                .keyboardType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.vertical, 9)
            }
            HairlineDivider()
            Button("Reload data") {
                Task { await store.loadAll() }
            }
            .padding(.vertical, 9)
            HairlineDivider()
        }
    }

    private func walletSection(_ wallet: Wallet) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Wallet").padding(.bottom, Theme.spacingS)
            HairlineDivider()
            settingsRow("ENS root", wallet.ensRoot)
            HairlineDivider()
            settingsRow("Address", wallet.address, monospaced: true)
            HairlineDivider()
            settingsRow("Agent address", wallet.agent, monospaced: true)
            HairlineDivider()
        }
    }

    private var aboutSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "About").padding(.bottom, Theme.spacingS)
            HairlineDivider()
            settingsRow("App", heroAppName)
            HairlineDivider()
            Link("Etherscan Sepolia", destination: URL(string: "https://sepolia.etherscan.io")!)
                .font(.subheadline)
                .padding(.vertical, 9)
            HairlineDivider()
            Link("World ID Simulator", destination: URL(string: "https://simulator.worldcoin.org")!)
                .font(.subheadline)
                .padding(.vertical, 9)
            HairlineDivider()
        }
    }

    private func settingsRow(_ label: String, _ value: String, monospaced: Bool = false) -> some View {
        HStack {
            Text(label).font(.subheadline).foregroundStyle(Theme.textPrimary)
            Spacer()
            Text(value)
                .font(monospaced ? .footnote.monospaced() : .subheadline)
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.vertical, 9)
    }
}
