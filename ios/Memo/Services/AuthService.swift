import Foundation
import Supabase

// 인증 상태 + 로그인/로그아웃. @MainActor Observable로 UI 바인딩.
@MainActor
@Observable
final class AuthService {
    enum Status: Equatable {
        case loading      // 초기 세션 복원 중
        case signedOut
        case signedIn(userId: UUID)
    }

    private(set) var status: Status = .loading
    var emailSent = false
    var lastError: String?

    private let auth = SupabaseManager.client.auth

    func start() async {
        // 저장된 세션 복원
        if let session = try? await auth.session {
            status = .signedIn(userId: session.user.id)
        } else {
            status = .signedOut
        }
        // 이후 상태 변화 구독
        for await change in auth.authStateChanges {
            switch change.event {
            case .signedIn, .tokenRefreshed, .initialSession:
                if let user = change.session?.user {
                    status = .signedIn(userId: user.id)
                }
            case .signedOut:
                status = .signedOut
            default:
                break
            }
        }
    }

    // Google OAuth — 외부 브라우저(ASWebAuthenticationSession) 세션. 콘솔 설정 필요.
    func signInWithGoogle() async {
        lastError = nil
        do {
            try await auth.signInWithOAuth(provider: .google, redirectTo: SupabaseManager.redirectURL)
        } catch {
            lastError = "Google 로그인 실패: \(error.localizedDescription)"
        }
    }

    // Apple 네이티브 로그인 — Apple이 준 idToken + raw nonce를 Supabase로.
    func signInWithApple(idToken: String, nonce: String) async {
        lastError = nil
        do {
            try await auth.signInWithIdToken(
                credentials: .init(provider: .apple, idToken: idToken, nonce: nonce)
            )
        } catch {
            lastError = "Apple 로그인 실패: \(error.localizedDescription)"
        }
    }

    // 이메일 매직링크(개발/대체). 인박스에서 링크 탭 → handle(url:)로 세션 복원.
    func signInWithEmail(_ email: String) async {
        lastError = nil; emailSent = false
        do {
            try await auth.signInWithOTP(email: email, redirectTo: SupabaseManager.redirectURL)
            emailSent = true
        } catch {
            lastError = "이메일 전송 실패: \(error.localizedDescription)"
        }
    }

    // 딥링크(OAuth 콜백 / 매직링크) 처리
    func handle(url: URL) async {
        do {
            try await auth.session(from: url)
        } catch {
            lastError = "세션 복원 실패: \(error.localizedDescription)"
        }
    }

    func signOut() async {
        try? await auth.signOut()
    }

    // 개발용: 익명 로그인(설정 없이 즉시 세션 → RLS/AI 파이프라인 검증). Supabase Anonymous 토글 필요.
    func signInAnonymously() async {
        lastError = nil
        do {
            try await auth.signInAnonymously()
        } catch {
            lastError = "익명 로그인 실패(Supabase Anonymous 활성 필요): \(error.localizedDescription)"
        }
    }
}
