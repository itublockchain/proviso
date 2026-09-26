import SwiftUI

struct SettingsView: View {
    @Environment(Store.self) private var store
    @State private var showWalletSetup = false
    @AppStorage("hero.showDemoControls") private var showDemoControls = false
    @State private var showResetConfirm = false
    @State private var isResetting = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.spacingXL) {
                    accountSection
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
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Hidden backup for the reset row below: works even with demo controls off.
                ToolbarItem(placement: .principal) {
                    Text("Settings").font(.headline)
                        .onTapGesture(count: 3) { showResetConfirm = true }
                }
            }
            .fullScreenCover(isPresented: $showWalletSetup) { WalletSetupView() }
            .onChange(of: store.walletStatus) { _, new in
                if new == .ready { showWalletSetup = false }
            }
            .confirmationDialog(
                "Reset & start over?",
                isPresented: $showResetConfirm,
                titleVisibility: .visible
            ) {
                Button("Reset & start over", role: .destructive) { runReset() }
            } message: {
                Text("Deletes your Proviso account, requests and orders, clears your wallet's setup on the contract and frees your name, so you can onboard again with the same wallet and World ID.")
            }
        }
    }

    private func runReset() {
        isResetting = true
        Task {
            await store.resetAndStartOver()
            isResetting = false
        }
    }

    private var accountSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Account").padding(.bottom, Theme.spacingS)
            HairlineDivider()
            if let me = store.me, me.signedIn {
                settingsRow(
                    "Signed in with World ID",
                    me.acr == orbVerifiedAcr ? "Orb-verified human" : "Verified"
                )
                HairlineDivider()
                if let sub = me.sub {
                    settingsRow("World ID", sub, monospaced: true)
                    HairlineDivider()
                }
                if let authTime = me.authTime {
                    settingsRow("Signed in", authTime.formatted(date: .abbreviated, time: .shortened))
                    HairlineDivider()
                }
            }
            Button("Replay intro") { store.replayIntro() }
                .padding(.vertical, 9)
            HairlineDivider()
            Button("Sign out", role: .destructive) {
                Task { await store.signOut() }
            }
            .padding(.vertical, 9)
            HairlineDivider()
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
            HairlineDivider()
            Toggle("Show demo controls", isOn: $showDemoControls)
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
            if showDemoControls {
                HairlineDivider()
                Button(role: .destructive) { showResetConfirm = true } label: {
                    HStack {
                        Text("Reset & start over")
                        if isResetting {
                            Spacer()
                            ProgressView()
                        }
                    }
                }
                .disabled(isResetting)
                .padding(.vertical, 9)
            }
            HairlineDivider()
        }
    }

    private func walletSection(_ wallet: Wallet) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionHeader(title: "Wallet").padding(.bottom, Theme.spacingS)
            HairlineDivider()
            settingsRow("Kind", store.walletStatus == .demo ? "Demo wallet (held by Proviso)" : "Your wallet")
            HairlineDivider()
            Link(destination: URL(string: "https://explorer.ens.dev/\(wallet.ensRoot)") ?? URL(string: "https://explorer.ens.dev")!) {
                settingsRow("ENS name", wallet.ensRoot)
            }
            HairlineDivider()
            settingsRow("Address", wallet.address.shortAddress, monospaced: true)
            HairlineDivider()
            settingsRow("Agent address", wallet.agent.shortAddress, monospaced: true)
            HairlineDivider()
            if store.walletStatus == .demo {
                Button("Set up my own wallet") { showWalletSetup = true }
                    .padding(.vertical, 9)
                HairlineDivider()
            }
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
