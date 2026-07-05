import SwiftUI
import AuthenticationServices

struct LoginView: View {
    let auth: AuthService
    @Environment(\.colorScheme) private var scheme
    @State private var currentNonce: String?

    var body: some View {
        ZStack {
            AppColor.bgCanvas.ignoresSafeArea()
            VStack(spacing: Space.x4) {
                Spacer()
                Text("memo").font(.appLargeTitle).foregroundStyle(AppColor.textPrimary)
                Text("생각을 적으면 AI가 정리해요")
                    .font(.appSubhead).foregroundStyle(AppColor.textSecondary)
                Spacer()

                // Google (웹 OAuth)
                PrimaryButton(title: "Google로 계속") {
                    Task { await auth.signInWithGoogle() }
                }

                // Apple (네이티브 Sign in with Apple)
                SignInWithAppleButton(.continue) { request in
                    let nonce = AppleNonce.random()
                    currentNonce = nonce
                    request.requestedScopes = [.fullName, .email]
                    request.nonce = AppleNonce.sha256(nonce)
                } onCompletion: { result in
                    switch result {
                    case .success(let authResults):
                        guard
                            let credential = authResults.credential as? ASAuthorizationAppleIDCredential,
                            let tokenData = credential.identityToken,
                            let idToken = String(data: tokenData, encoding: .utf8),
                            let nonce = currentNonce
                        else {
                            auth.lastError = "Apple 토큰을 읽지 못했습니다."
                            return
                        }
                        Task { await auth.signInWithApple(idToken: idToken, nonce: nonce) }
                    case .failure(let error):
                        auth.lastError = "Apple 로그인 취소/실패: \(error.localizedDescription)"
                    }
                }
                .signInWithAppleButtonStyle(scheme == .dark ? .white : .black)
                .frame(height: 52)
                .clipShape(RoundedRectangle(cornerRadius: Radius.md, style: .continuous))

                if let err = auth.lastError {
                    Text(err).font(.appCaption).foregroundStyle(AppColor.danger)
                }

                #if DEBUG
                Button("개발용: 익명 로그인") {
                    Task { await auth.signInAnonymously() }
                }
                .font(.appFootnote).foregroundStyle(AppColor.textTertiary)
                #endif
            }
            .padding(Space.x6)
        }
    }
}
