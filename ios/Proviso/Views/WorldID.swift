import SwiftUI

/// Big monospaced World ID user code + hint, shown while waiting for the human to confirm
/// (used by both per-order approval and the one-time agent link flow).
struct WorldIDCodeCard: View {
    let code: String

    var body: some View {
        ProvisoCard {
            VStack(spacing: 12) {
                Label("Confirm with World ID", systemImage: "checkmark.seal.fill")
                    .font(.headline)
                    .foregroundStyle(Theme.accentGreen)
                Text(code)
                    .font(.system(size: 40, weight: .bold, design: .monospaced))
                    .kerning(4)
                    .foregroundStyle(Theme.textPrimary)
                Text("Make sure World ID shows this code")
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

/// "This agent works for me" — one-time World ID link. Shows Linked ✓, or a button that starts
/// the link flow and presents ``WorldIDLinkSheet`` until it resolves.
struct WorldIDLinkRow: View {
    @Environment(Store.self) private var store
    let worldLinked: Bool
    @State private var linking = false
    @State private var activeLink: WorldLink?
    @State private var errorText: String?

    var body: some View {
        HStack {
            Label("World ID", systemImage: "checkmark.seal")
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            if worldLinked {
                Label("Linked", systemImage: "checkmark.circle.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.accentGreen)
            } else {
                Button(linking ? "Linking…" : "Link World ID") {
                    Task { await startLink() }
                }
                .font(.subheadline.weight(.semibold))
                .disabled(linking)
            }
        }
        .sheet(item: $activeLink) { link in
            WorldIDLinkSheet(link: link)
        }
        .alert("World ID", isPresented: Binding(
            get: { errorText != nil },
            set: { if !$0 { errorText = nil } }
        )) {
            Button("OK") { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
    }

    private func startLink() async {
        linking = true
        defer { linking = false }
        do {
            activeLink = try await store.startWorldLink()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

/// Sheet shown while a World ID link is pending: the code, a button that opens the sandbox
/// verification page in-app, and polling until the link resolves.
private struct WorldIDLinkSheet: View {
    @Environment(Store.self) private var store
    @Environment(\.dismiss) private var dismiss
    let link: WorldLink
    @State private var status: WorldLinkStatus = .pending
    @State private var errorText: String?
    @State private var showSafari = false
    @State private var pollTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    switch status {
                    case .pending:
                        WorldIDCodeCard(code: link.userCode)
                        Button {
                            showSafari = true
                        } label: {
                            Label("Link with World ID", systemImage: "person.fill.checkmark")
                                .frame(maxWidth: .infinity)
                                .fontWeight(.semibold)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(Theme.accentGreen)
                    case .linked:
                        ProvisoCard {
                            VStack(spacing: 10) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 44))
                                    .foregroundStyle(Theme.accentGreen)
                                Text("World ID linked").font(.headline).foregroundStyle(Theme.textPrimary)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    case .denied, .expired:
                        ProvisoCard {
                            VStack(alignment: .leading, spacing: 6) {
                                Label(status == .expired ? "Link expired" : "Link denied", systemImage: "xmark.shield.fill")
                                    .font(.headline)
                                    .foregroundStyle(Theme.accentRed)
                                Text(errorText ?? "Try linking again from Budgets.")
                                    .font(.subheadline)
                                    .foregroundStyle(Theme.textSecondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .padding(16)
                .animation(.spring(duration: 0.45), value: status)
            }
            .background(Theme.background)
            .navigationTitle("Link World ID")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .sheet(isPresented: $showSafari) {
                if let url = URL(string: link.approvalUrl) { SafariView(url: url) }
            }
        }
        .task { startPolling() }
        .onDisappear { pollTask?.cancel() }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let result = try? await store.worldLinkStatus(id: link.linkId) else { continue }
                if result.status != .pending { showSafari = false }
                status = result.status
                errorText = result.error
                if result.status != .pending {
                    if result.status == .linked { await store.loadAll() }
                    break
                }
            }
        }
    }
}
