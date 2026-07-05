import Foundation
import Supabase

// Supabase 클라이언트 싱글톤. anon/publishable 키만(Info.plist ← xcconfig).
enum SupabaseManager {
    static let client: SupabaseClient = {
        guard
            let urlString = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String,
            let url = URL(string: urlString),
            let key = Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String,
            !key.isEmpty
        else {
            fatalError("SUPABASE_URL / SUPABASE_ANON_KEY 누락 — Secrets.xcconfig 확인")
        }
        return SupabaseClient(supabaseURL: url, supabaseKey: key)
    }()

    // OAuth / 매직링크 리다이렉트 (Info.plist URL scheme + Supabase redirect 허용목록과 일치)
    static let redirectURL = URL(string: "com.duovelop.memo://login-callback")!
}
