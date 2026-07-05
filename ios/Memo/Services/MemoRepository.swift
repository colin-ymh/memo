import Foundation
import Supabase

// 데이터 접근 추상화(advisor: 프로토콜 뒤에 둬서 나중에 로컬캐시/동기화로 교체 쉽게).
protocol MemoRepository: Sendable {
    func fetchMemos() async throws -> [Memo]
    func fetchCategories() async throws -> [Category]
    func createMemo(content: String) async throws -> Memo
    func softDeleteMemo(id: UUID) async throws
}

// PostgREST row(snake_case). 날짜는 문자열로 받아 안전하게 파싱.
private struct MemoRow: Decodable {
    let id: UUID
    let content: String
    let category_id: UUID?
    let embedding_model: String?
    let created_at: String
    let updated_at: String
    let deleted_at: String?
}
private struct CategoryRow: Decodable {
    let id: UUID
    let name: String
    let created_by_ai: Bool
}

// ISO8601DateFormatter는 스레드세이프(파싱/포맷). Swift6에 Sendable로 인식 안 돼 표시.
private nonisolated(unsafe) let iso: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f
}()
private func parseDate(_ s: String?) -> Date {
    guard let s else { return Date() }
    return iso.date(from: s) ?? ISO8601DateFormatter().date(from: s) ?? Date()
}

struct SupabaseMemoRepository: MemoRepository {
    private var client: SupabaseClient { SupabaseManager.client }
    private let selectCols = "id,content,category_id,embedding_model,created_at,updated_at,deleted_at"

    func fetchMemos() async throws -> [Memo] {
        let rows: [MemoRow] = try await client
            .from("memos")
            .select(selectCols)
            .is("deleted_at", value: nil)
            .order("created_at", ascending: false)
            .execute()
            .value
        return rows.map(map)
    }

    func fetchCategories() async throws -> [Category] {
        let rows: [CategoryRow] = try await client
            .from("categories")
            .select("id,name,created_by_ai")
            .execute()
            .value
        return rows.map { Category(id: $0.id, name: $0.name, createdByAi: $0.created_by_ai) }
    }

    func createMemo(content: String) async throws -> Memo {
        guard let userId = client.auth.currentUser?.id else {
            throw NSError(domain: "memo", code: 401,
                          userInfo: [NSLocalizedDescriptionKey: "로그인 필요"])
        }
        // RLS: user_id = auth.uid() 필수(스키마에 default 없음)라 명시 전달.
        struct Insert: Encodable { let user_id: UUID; let content: String }
        let row: MemoRow = try await client
            .from("memos")
            .insert(Insert(user_id: userId, content: content))
            .select(selectCols)
            .single()
            .execute()
            .value
        return map(row)
    }

    func softDeleteMemo(id: UUID) async throws {
        try await client
            .from("memos")
            .update(["deleted_at": iso.string(from: Date())])
            .eq("id", value: id)
            .execute()
    }

    private func map(_ r: MemoRow) -> Memo {
        Memo(id: r.id, content: r.content, categoryId: r.category_id,
             embeddingModel: r.embedding_model,
             createdAt: parseDate(r.created_at), updatedAt: parseDate(r.updated_at),
             deletedAt: r.deleted_at.map { parseDate($0) })
    }
}
