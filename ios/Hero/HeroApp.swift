import SwiftUI

@main
struct HeroApp: App {
    @State private var store = Store()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(store)
                .task {
                    await store.loadSession()
                    await runUITestHooks()
                }
                .onOpenURL { store.handleDeepLink($0) }
        }
    }

    /// QA-only launch-argument seam so simulator screenshots can be scripted without a real tap
    /// (accessibility/UI automation isn't available in the build sandbox). No-op in normal runs.
    private func runUITestHooks() async {
        let args = ProcessInfo.processInfo.arguments
        if args.contains("-uiTestDemo") {
            await store.signInWithDemo()
            try? await store.useDemoWallet()
        }
        if let idx = args.firstIndex(of: "-uiTestOpenRequest"), idx + 1 < args.count,
           let url = URL(string: "proviso://request/\(args[idx + 1])") {
            store.handleDeepLink(url)
        }
    }
}

/// Top-level gate: first-launch onboarding (which ends in mandatory sign-in), then sign-in
/// whenever there's no active session, then the app itself.
struct RootView: View {
    @Environment(Store.self) private var store

    var body: some View {
        Group {
            if !store.onboardingSeen {
                OnboardingView()
            } else {
                switch store.authPhase {
                case .loading:
                    Theme.background.ignoresSafeArea()
                case .signedOut:
                    SignInView()
                case .signedIn:
                    if store.walletStatus == .ready || store.walletStatus == .demo {
                        RootTabView()
                    } else {
                        WalletSetupView()
                    }
                }
            }
        }
        .animation(.default, value: store.onboardingSeen)
        .animation(.default, value: store.walletStatus)
        // Lives above the onboarding/sign-in/app switch, so a reset's toast survives the jump
        // back to onboarding instead of dying with the Settings view it was shown from.
        .overlay(alignment: .bottom) {
            if let message = store.toastMessage {
                ToastBanner(message: message)
                    .padding(.bottom, 40)
                    .task {
                        try? await Task.sleep(for: .seconds(3))
                        store.toastMessage = nil
                    }
            }
        }
        .animation(.default, value: store.toastMessage)
    }
}

struct RootTabView: View {
    @Environment(Store.self) private var store
    private static let composeTab = 99

    var body: some View {
        @Bindable var store = store
        TabView(selection: $store.selectedTab) {
            Tab("Requests", systemImage: "list.bullet.rectangle", value: 0) {
                RequestsListView()
            }
            Tab("Approvals", systemImage: "checkmark.shield", value: 1) {
                ApprovalsListView()
            }
            Tab("Budgets", systemImage: "chart.pie", value: 2) {
                BudgetsView()
            }
            Tab("Settings", systemImage: "gearshape", value: 3) {
                SettingsView()
            }
            // The search role puts this tab in its own circle at the trailing end of the tab bar.
            Tab("New request", systemImage: "plus", value: Self.composeTab, role: .search) {
                Color.clear
            }
        }
        .tint(Theme.accentBlue)
        .onChange(of: store.selectedTab) { old, new in
            guard new == Self.composeTab else { return }
            store.selectedTab = old
            store.showingComposer = true
        }
        .sheet(isPresented: $store.showingComposer) {
            NewRequestComposerView()
        }
    }
}
