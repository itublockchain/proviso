import SwiftUI

@main
struct HeroApp: App {
    @State private var store = Store()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(store)
                .task { await store.loadAll() }
                .onOpenURL { store.handleDeepLink($0) }
        }
    }
}

struct RootTabView: View {
    @Environment(Store.self) private var store

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
        }
        .tint(Theme.accentBlue)
    }
}
