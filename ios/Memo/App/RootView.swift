import SwiftUI

// 인증 상태에 따라 로그인 / 목록 분기.
struct RootView: View {
    let auth: AuthService

    var body: some View {
        switch auth.status {
        case .loading:
            ZStack {
                AppColor.bgCanvas.ignoresSafeArea()
                DotSpinner(size: 28)
            }
        case .signedOut:
            LoginView(auth: auth)
        case .signedIn:
            MemoListView()
        }
    }
}
