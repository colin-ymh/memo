import Foundation
import Supabase

// 시맨틱 검색 결과(Edge Function 반환).
struct SemanticHit: Decodable, Sendable, Identifiable {
    let id: UUID
    let similarity: Double
}

// 데이터 접근 추상화(advisor: 프로토콜 뒤에 둬서 나중에 로컬캐시/동기화로 교체 쉽게).
protocol MemoRepository: Sendable {
    func fetchMemos() async throws -> [Memo]
    func fetchCategories() async throws -> [Category]
    func createMemo(id: UUID, content: String) async throws
    func updateMemo(memoId: UUID, content: String) async throws
    func softDeleteMemo(id: UUID) async throws
    func relatedMemos(memoId: UUID) async throws -> [RelatedMemo]
    func setCategory(memoId: UUID, categoryId: UUID?) async throws
    func setPinned(memoId: UUID, pinned: Bool) async throws
    func searchSemantic(query: String, count: Int) async throws -> [SemanticHit]
    func createCategory(name: String) async throws -> Category
    func renameCategory(id: UUID, name: String) async throws
    func mergeCategory(source: UUID, into target: UUID) async throws
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
    let is_pinned: Bool?
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
    private let selectCols = "id,content,category_id,embedding_model,created_at,updated_at,deleted_at,is_pinned"

    func fetchMemos() async throws -> [Memo] {
        let rows: [MemoRow] = try await client
            .from("memos")
            .select(selectCols)
            .is("deleted_at", value: nil)
            .order("is_pinned", ascending: false)
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

    // 클라이언트가 id를 생성해 넘긴다 → 오프라인 생성분이 온라인 flush돼도 같은 id(서버id=로컬id).
    func createMemo(id: UUID, content: String) async throws {
        guard let userId = client.auth.currentUser?.id else {
            throw NSError(domain: "memo", code: 401,
                          userInfo: [NSLocalizedDescriptionKey: "로그인 필요"])
        }
        // RLS: user_id = auth.uid() 필수(스키마에 default 없음)라 명시 전달.
        // upsert(ignoreDuplicates): flush 재시도가 중복 insert돼도 PK 충돌 없이 멱등.
        struct Insert: Encodable { let id: UUID; let user_id: UUID; let content: String }
        try await client
            .from("memos")
            .upsert(Insert(id: id, user_id: userId, content: content),
                    onConflict: "id", ignoreDuplicates: true)
            .execute()
    }

    // 주의: 내용 편집은 재분류를 트리거하지 않는다(webhook은 INSERT 전용).
    // 카테고리/임베딩은 유지 → 재임베딩은 추후 항목.
    func updateMemo(memoId: UUID, content: String) async throws {
        struct Upd: Encodable { let content: String }
        try await client
            .from("memos")
            .update(Upd(content: content))
            .eq("id", value: memoId)
            .execute()
    }

    func softDeleteMemo(id: UUID) async throws {
        try await client
            .from("memos")
            .update(["deleted_at": iso.string(from: Date())])
            .eq("id", value: id)
            .execute()
    }

    func relatedMemos(memoId: UUID) async throws -> [RelatedMemo] {
        struct Params: Encodable { let p_memo_id: UUID }
        struct RelatedRow: Decodable {
            let id: UUID; let content: String; let category_id: UUID?; let similarity: Double
        }
        let rows: [RelatedRow] = try await client
            .rpc("related_memos", params: Params(p_memo_id: memoId))
            .execute()
            .value
        return rows.map {
            RelatedMemo(id: $0.id, content: $0.content, categoryId: $0.category_id, similarity: $0.similarity)
        }
    }

    func setCategory(memoId: UUID, categoryId: UUID?) async throws {
        struct Upd: Encodable { let category_id: UUID? }
        try await client.from("memos")
            .update(Upd(category_id: categoryId))
            .eq("id", value: memoId)
            .execute()
    }

    func createCategory(name: String) async throws -> Category {
        guard let userId = client.auth.currentUser?.id else {
            throw NSError(domain: "memo", code: 401,
                          userInfo: [NSLocalizedDescriptionKey: "로그인 필요"])
        }
        // 사용자 정의 카테고리(created_by_ai=false). 같은 이름 있으면 그거 재사용(upsert).
        struct Ins: Encodable { let user_id: UUID; let name: String; let created_by_ai: Bool }
        let row: CategoryRow = try await client.from("categories")
            .upsert(Ins(user_id: userId, name: name, created_by_ai: false), onConflict: "user_id,name")
            .select("id,name,created_by_ai")
            .single()
            .execute()
            .value
        return Category(id: row.id, name: row.name, createdByAi: row.created_by_ai)
    }

    // 카테고리 이름 변경. unique(user_id,name) 충돌 시 오류 → 호출부에서 "병합" 유도.
    func renameCategory(id: UUID, name: String) async throws {
        struct Upd: Encodable { let name: String }
        try await client.from("categories")
            .update(Upd(name: name))
            .eq("id", value: id)
            .execute()
    }

    // source 카테고리의 메모를 target으로 옮기고 source 삭제(서버 트랜잭션 RPC).
    func mergeCategory(source: UUID, into target: UUID) async throws {
        struct Params: Encodable { let p_source: UUID; let p_target: UUID }
        try await client
            .rpc("merge_categories", params: Params(p_source: source, p_target: target))
            .execute()
    }

    // 시맨틱 검색 — Edge Function(쿼리 임베딩 + match_memos). 유저 토큰 자동 첨부.
    func searchSemantic(query: String, count: Int) async throws -> [SemanticHit] {
        struct Body: Encodable { let query: String; let count: Int }
        struct Resp: Decodable { let results: [SemanticHit] }
        let resp: Resp = try await client.functions.invoke(
            "search-memos", options: .init(body: Body(query: query, count: count)))
        return resp.results
    }

    func setPinned(memoId: UUID, pinned: Bool) async throws {
        struct Upd: Encodable { let is_pinned: Bool }
        try await client.from("memos")
            .update(Upd(is_pinned: pinned))
            .eq("id", value: memoId)
            .execute()
    }

    private func map(_ r: MemoRow) -> Memo {
        Memo(id: r.id, content: r.content, categoryId: r.category_id,
             embeddingModel: r.embedding_model,
             createdAt: parseDate(r.created_at), updatedAt: parseDate(r.updated_at),
             deletedAt: r.deleted_at.map { parseDate($0) },
             isPinned: r.is_pinned ?? false)
    }
}
