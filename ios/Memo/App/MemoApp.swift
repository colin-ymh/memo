import SwiftUI

@main
struct MemoApp: App {
    @State private var auth = AuthService()
    @State private var settings = AppSettings.shared

    var body: some Scene {
        WindowGroup {
            RootView(auth: auth)
                .task { await auth.start() }
                // 테마·언어 override(설정에서 변경 시 즉시 반영). .system은 각각 OS/기기 따름.
                .preferredColorScheme(settings.themeMode.colorScheme)
                .environment(\.locale, settings.appLanguage.locale)
            // 주의: Google OAuth는 signInWithOAuth가 ASWebAuthenticationSession으로
            // 콜백을 내부 처리한다. 여기서 onOpenURL→session(from:)을 또 부르면
            // 같은 authorization code를 두 번 교환해 PKCE("code verifier") 불일치가 난다.
            // 매직링크(이메일)를 다시 쓸 땐 OAuth 콜백과 구분해서 처리할 것.
        }
    }
}
