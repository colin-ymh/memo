import SwiftUI

@main
struct MemoApp: App {
    @State private var auth = AuthService()

    var body: some Scene {
        WindowGroup {
            RootView(auth: auth)
                .task { await auth.start() }
                .onOpenURL { url in
                    Task { await auth.handle(url: url) }
                }
        }
    }
}
