import SwiftUI
import UIKit

/// Full-screen step shown after sign-in (and the optional first-run budgets step) whenever the
/// account's wallet isn't set up yet. Matches the onboarding/sign-in visual style. Terminal states
/// (walletStatus == .ready or .demo) make RootView swap this out for RootTabView on its own.
struct WalletSetupView: View {
    @Environment(Store.self) private var store
    @Environment(\.scenePhase) private var scenePhase

    @State private var handle = ""
    @State private var isConnecting = false
    @State private var isWaiting = false
    @State private var succeeded = false
    @State private var walletStart: WalletStart?
    @State private var showFallbackLink = false
    @State private var errorText: String?
    @State private var pollTask: Task<Void, Never>?

    private var previewName: String {
        let cleaned = Self.sanitize(handle)
        return cleaned.isEmpty ? "you.herodemo.eth" : "\(cleaned).herodemo.eth"
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            WalletSetupIllustration(stage: succeeded ? .done : (isWaiting ? .waiting : .idle), name: previewName)
                .frame(height: 200)
            content
            Spacer()
            actions
        }
        .padding(.horizontal, Theme.spacingL)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .onDisappear { pollTask?.cancel() }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, isWaiting, !succeeded else { return }
            Task { await pollOnce() }
        }
        .alert("Couldn't connect", isPresented: Binding(
            get: { errorText != nil },
            set: { if !$0 { errorText = nil } }
        )) {
            Button("OK") { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
    }

    @ViewBuilder
    private var content: some View {
        if succeeded {
            Text("\(previewName) is yours")
                .font(.system(size: 26, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, Theme.spacingL)
        } else {
            VStack(spacing: Theme.spacingM) {
                VStack(spacing: Theme.spacingS) {
                    Text("Connect your wallet")
                        .font(.system(size: 28, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.textPrimary)
                        .multilineTextAlignment(.center)
                    Text("Hero shops from your own wallet — no deposits. You'll sign three things in MetaMask:")
                        .font(.body)
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                }

                VStack(alignment: .leading, spacing: Theme.spacingS) {
                    stepRow("Let Hero's contract spend, only within your rules")
                    stepRow("Point it to your rules on your ENS name")
                    stepRow("Lock bigger buys to your World ID")
                }
                .padding(.top, Theme.spacingS)

                if isWaiting {
                    statusLine
                } else {
                    handleField
                }
            }
            .padding(.horizontal, Theme.spacingL)
        }
    }

    private var handleField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Choose your name").font(.caption.weight(.semibold)).foregroundStyle(Theme.textSecondary)
            TextField("auto", text: $handle)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onChange(of: handle) { _, new in handle = Self.sanitize(new) }
            Text(previewName).font(.caption.monospaced()).foregroundStyle(Theme.textSecondary)
        }
        .padding(.top, Theme.spacingM)
    }

    private var statusLine: some View {
        HStack(spacing: Theme.spacingS) {
            ProgressView()
            Text("Waiting for MetaMask… Hero is setting up \(previewName)")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.top, Theme.spacingM)
    }

    private func stepRow(_ text: String) -> some View {
        HStack(alignment: .top, spacing: Theme.spacingS) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accentGreen).font(.subheadline)
            Text(text).font(.subheadline).foregroundStyle(Theme.textPrimary)
        }
    }

    @ViewBuilder
    private var actions: some View {
        if succeeded {
            EmptyView()
        } else if isWaiting {
            VStack(spacing: Theme.spacingS) {
                if showFallbackLink, let walletStart {
                    Button {
                        UIPasteboard.general.string = walletStart.pageUrl
                    } label: {
                        Label("Copy link", systemImage: "doc.on.doc")
                    }
                    .font(.footnote)
                }
                Button("Use demo wallet (held by Hero)") { Task { await useDemoWallet() } }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Theme.textSecondary)
                Button("Cancel") { cancelWaiting() }
                    .font(.footnote)
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.bottom, Theme.spacingXL)
        } else {
            VStack(spacing: Theme.spacingS) {
                Button {
                    Task { await connect() }
                } label: {
                    Text(isConnecting ? "Connecting…" : "Connect MetaMask")
                        .foregroundStyle(Theme.background)
                        .frame(maxWidth: .infinity)
                        .fontWeight(.semibold)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.textPrimary)
                .disabled(isConnecting)

                if let walletStart, let url = URL(string: walletStart.pageUrl) {
                    ShareLink(item: url) {
                        Text("Open on computer")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Theme.textPrimary)
                    }
                }

                Button("Use demo wallet (held by Hero)") { Task { await useDemoWallet() } }
                    .font(.subheadline)
                    .foregroundStyle(Theme.textSecondary)
                    .disabled(isConnecting)
            }
            .padding(.bottom, Theme.spacingXL)
        }
    }

    private static func sanitize(_ raw: String) -> String {
        String(raw.lowercased().filter { $0.isLowercase || $0.isNumber || $0 == "-" }.prefix(24))
    }

    private func connect() async {
        isConnecting = true
        defer { isConnecting = false }
        do {
            let start = try await store.startWallet(handle: handle.isEmpty ? nil : handle)
            walletStart = start
            isWaiting = true
            if let url = URL(string: start.url) {
                UIApplication.shared.open(url, options: [.universalLinksOnly: true]) { opened in
                    if !opened { showFallbackLink = true }
                }
            } else {
                showFallbackLink = true
            }
            startPolling()
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func useDemoWallet() async {
        do {
            try await store.useDemoWallet()
            withAnimation(.spring(duration: 0.4)) { succeeded = true }
        } catch {
            errorText = error.localizedDescription
        }
    }

    private func cancelWaiting() {
        pollTask?.cancel()
        isWaiting = false
        walletStart = nil
        showFallbackLink = false
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                if Task.isCancelled { break }
                await pollOnce()
                if succeeded { break }
            }
        }
    }

    private func pollOnce() async {
        await store.loadSession()
        if store.walletStatus == .ready || store.walletStatus == .demo {
            withAnimation(.spring(duration: 0.4)) { succeeded = true }
        }
    }
}

/// wallet -> your name chip -> shield, matching the onboarding illustration style.
private struct WalletSetupIllustration: View {
    enum Stage { case idle, waiting, done }
    let stage: Stage
    let name: String
    @State private var appeared = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "wallet.bifold.fill")
                .font(.system(size: 40))
                .foregroundStyle(Theme.accentBlue)
            Image(systemName: "arrow.right")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary.opacity(0.5))
            Text(name)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Theme.secondaryBackground)
                .foregroundStyle(Theme.textPrimary)
                .clipShape(Capsule())
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
            Image(systemName: "arrow.right")
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary.opacity(0.5))
            Image(systemName: stage == .done ? "checkmark.shield.fill" : "shield.fill")
                .font(.system(size: 40))
                .foregroundStyle(stage == .done ? Theme.accentGreen : Theme.accentBlue)
                .symbolEffect(.bounce, value: stage == .done)
        }
        .scaleEffect(appeared ? 1 : 0.85)
        .opacity(appeared ? 1 : 0)
        .animation(.spring(duration: 0.5), value: appeared)
        .onAppear { withAnimation(.spring(duration: 0.5)) { appeared = true } }
    }
}
