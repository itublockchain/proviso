import SwiftUI

/// Mandatory Sign in with World ID gate — shown as the last onboarding page, and again any time
/// there's no active session (sign-out, expired session).
struct SignInPanel: View {
    @Environment(Store.self) private var store
    var onSignedIn: () -> Void = {}

    @State private var isSigningIn = false
    @State private var errorText: String?

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            VStack(spacing: Theme.spacingM) {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(Theme.accentGreen)
                    .symbolEffect(.bounce, value: isSigningIn)
                Text("Sign in with World ID")
                    .font(.system(size: 30, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center)
                Text("One verified human, one account. Proviso works for you and no one else.")
                    .font(.body)
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, Theme.spacingL)
            Spacer()
            VStack(spacing: Theme.spacingS) {
                Button {
                    Task { await signIn() }
                } label: {
                    Text(isSigningIn ? "Opening World ID…" : "Sign in with World ID")
                        .foregroundStyle(Theme.background)
                        .frame(maxWidth: .infinity)
                        .fontWeight(.semibold)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.textPrimary)
                .disabled(isSigningIn)

                Button("Explore demo") {
                    Task {
                        await store.signInWithDemo()
                        onSignedIn()
                    }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.textSecondary)
                .disabled(isSigningIn)
            }
            .padding(.horizontal, Theme.spacingL)
            .padding(.bottom, Theme.spacingXL)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.background)
        .alert("Sign-in failed", isPresented: Binding(
            get: { errorText != nil },
            set: { if !$0 { errorText = nil } }
        )) {
            Button("OK") { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
    }

    private func signIn() async {
        isSigningIn = true
        defer { isSigningIn = false }
        do {
            try await store.signInWithWorldID()
            onSignedIn()
        } catch {
            errorText = error.localizedDescription
        }
    }
}

/// Standalone sign-in screen shown post-onboarding (sign-out, expired session).
struct SignInView: View {
    var body: some View {
        SignInPanel()
    }
}
