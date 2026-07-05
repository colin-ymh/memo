import SwiftUI

@main
struct MemoApp: App {
    @State private var auth = AuthService()

    var body: some Scene {
        WindowGroup {
            RootView(auth: auth)
                .task { await auth.start() }
            // 주의: Google OAuth는 signInWithOAuth가 ASWebAuthenticationSession으로
            // 콜백을 내부 처리한다. 여기서 onOpenURL→session(from:)을 또 부르면
            // 같은 authorization code를 두 번 교환해 PKCE("code verifier") 불일치가 난다.
            // 매직링크(이메일)를 다시 쓸 땐 OAuth 콜백과 구분해서 처리할 것.
        }
    }
}
