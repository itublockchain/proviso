import AuthenticationServices
import UIKit

/// Friendly, user-facing errors for the "Sign in with World ID" browser flow.
enum WorldSignInError: LocalizedError {
    case cancelled
    case notOwner
    case worldID3NotAvailable
    case other(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: return "You cancelled in World ID"
        case .notOwner: return "This Hero account belongs to a different World ID"
        case .worldID3NotAvailable: return "This World ID can't sign in here yet"
        case .other: return "Sign-in failed, try again"
        }
    }

    static func from(code: String) -> WorldSignInError {
        switch code {
        case "access_denied": return .cancelled
        case "not_owner": return .notOwner
        case "world_id_3_not_available": return .worldID3NotAvailable
        default: return .other(code)
        }
    }
}

/// Runs `<backend>/auth/world/start` in an ASWebAuthenticationSession and resolves with the
/// opaque session token carried back on `hero://auth?session=...` (or throws on `?error=...`).
@MainActor
final class WorldSignInController: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?

    func signIn(backendBase: URL) async throws -> String {
        var components = URLComponents(url: backendBase.appendingPathComponent("auth/world/start"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "return", value: "hero")]
        let url = components.url!

        return try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: "hero") { callbackURL, error in
                if let error {
                    let nsError = error as NSError
                    if nsError.domain == ASWebAuthenticationSessionErrorDomain,
                       nsError.code == ASWebAuthenticationSessionError.canceledLogin.rawValue {
                        continuation.resume(throwing: WorldSignInError.cancelled)
                    } else {
                        continuation.resume(throwing: WorldSignInError.other(error.localizedDescription))
                    }
                    return
                }
                guard let callbackURL,
                      let items = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false)?.queryItems else {
                    continuation.resume(throwing: WorldSignInError.other("no_callback"))
                    return
                }
                if let code = items.first(where: { $0.name == "error" })?.value {
                    continuation.resume(throwing: WorldSignInError.from(code: code))
                } else if let token = items.first(where: { $0.name == "session" })?.value {
                    continuation.resume(returning: token)
                } else {
                    continuation.resume(throwing: WorldSignInError.other("missing_session"))
                }
            }
            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = false
            self.session = session
            session.start()
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        for scene in UIApplication.shared.connectedScenes {
            if let windowScene = scene as? UIWindowScene,
               let window = windowScene.windows.first(where: { $0.isKeyWindow }) {
                return window
            }
        }
        return ASPresentationAnchor()
    }
}
