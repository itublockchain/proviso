import SwiftUI

struct SettingsView: View {
    @Environment(Store.self) private var store

    var body: some View {
        NavigationStack {
            Form {
                Section("Backend") {
                    Toggle("Demo mode (mock data)", isOn: Binding(
                        get: { store.demoMode },
                        set: { store.demoMode = $0 }
                    ))
                    if !store.demoMode {
                        TextField("Backend URL", text: Binding(
                            get: { store.backendURLString },
                            set: { store.backendURLString = $0 }
                        ))
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    }
                    Button("Reload data") {
                        Task { await store.loadAll() }
                    }
                }

                if let wallet = store.budgets?.wallet {
                    Section("Wallet") {
                        LabeledContent("ENS root", value: wallet.ensRoot)
                        LabeledContent("Address", value: wallet.address).font(.footnote.monospaced())
                        LabeledContent("Agent address", value: wallet.agent).font(.footnote.monospaced())
                    }
                }

                Section("About") {
                    LabeledContent("App", value: heroAppName)
                    Link("Etherscan Sepolia", destination: URL(string: "https://sepolia.etherscan.io")!)
                    Link("World ID Simulator", destination: URL(string: "https://simulator.worldcoin.org")!)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Theme.background)
            .navigationTitle("Settings")
        }
    }
}
