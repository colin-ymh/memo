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
    func fetchFolders() async throws -> [Folder]
    func createMemo(id: UUID, content: String, folderId: UUID?) async throws
    func updateMemo(memoId: UUID, content: String) async throws
    func softDeleteMemo(id: UUID) async throws
    func relatedMemos(memoId: UUID) async throws -> [RelatedMemo]
    func setFolder(memoId: UUID, folderId: UUID?) async throws
    func setPinned(memoId: UUID, pinned: Bool) async throws
    func searchSemantic(query: String, count: Int) async throws -> [SemanticHit]
    // 폴더 트리 CRUD. 깊이(≤3)·순환은 서버 트리거가 최종 방어(앱도 사전 차단).
    func createFolder(title: String, description: String?, parentId: UUID?) async throws -> Folder
    func updateFolder(id: UUID, title: String, description: String?) async throws
    func reparentFolder(id: UUID, parentId: UUID?) async throws
    func deleteFolder(id: UUID) async throws   // 빈 폴더만(호출부에서 사전 확인)
}

// PostgREST row(snake_case). 날짜는 문자열로 받아 안전하게 파싱.
private struct MemoRow: Decodable {
    let id: UUID
    let content: String
    let folder_id: UUID?
    let embedding_model: String?
    let created_at: String
    let updated_at: String
    let deleted_at: String?
    let is_pinned: Bool?
}
private struct FolderRow: Decodable {
    let id: UUID
    let parent_id: UUID?
    let title: String
    let description: String?
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
    private let selectCols = "id,content,folder_id,embedding_model,created_at,updated_at,deleted_at,is_pinned"

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

    func fetchFolders() async throws -> [Folder] {
        let rows: [FolderRow] = try await client
            .from("folders")
            .select("id,parent_id,title,description")
            .execute()
            .value
        return rows.map { Folder(id: $0.id, parentId: $0.parent_id, title: $0.title, description: $0.description) }
    }

    // 클라이언트가 id를 생성해 넘긴다 → 오프라인 생성분이 온라인 flush돼도 같은 id(서버id=로컬id).
    func createMemo(id: UUID, content: String, folderId: UUID?) async throws {
        guard let userId = client.auth.currentUser?.id else {
            throw NSError(domain: "memo", code: 401,
                          userInfo: [NSLocalizedDescriptionKey: "로그인 필요"])
        }
        // RLS: user_id = auth.uid() 필수(스키마에 default 없음)라 명시 전달.
        // folder_id 지정 시 process-memo가 분류를 건너뛰고 그 폴더 유지(임베딩만).
        // upsert(ignoreDuplicates): flush 재시도가 중복 insert돼도 PK 충돌 없이 멱등.
        struct Insert: Encodable { let id: UUID; let user_id: UUID; let content: String; let folder_id: UUID? }
        try await client
            .from("memos")
            .upsert(Insert(id: id, user_id: userId, content: content, folder_id: folderId),
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
            let id: UUID; let content: String; let folder_id: UUID?; let similarity: Double
        }
        let rows: [RelatedRow] = try await client
            .rpc("related_memos", params: Params(p_memo_id: memoId))
            .execute()
            .value
        return rows.map {
            RelatedMemo(id: $0.id, content: $0.content, folderId: $0.folder_id, similarity: $0.similarity)
        }
    }

    func setFolder(memoId: UUID, folderId: UUID?) async throws {
        struct Upd: Encodable { let folder_id: UUID? }
        try await client.from("memos")
            .update(Upd(folder_id: folderId))
            .eq("id", value: memoId)
            .execute()
    }

    func createFolder(title: String, description: String?, parentId: UUID?) async throws -> Folder {
        guard let userId = client.auth.currentUser?.id else {
            throw NSError(domain: "memo", code: 401,
                          userInfo: [NSLocalizedDescriptionKey: "로그인 필요"])
        }
        // 깊이(≤3)·순환·형제 이름 중복은 서버(트리거/유니크 인덱스)가 강제 → 위반 시 throw.
        struct Ins: Encodable { let user_id: UUID; let parent_id: UUID?; let title: String; let description: String? }
        let row: FolderRow = try await client.from("folders")
            .insert(Ins(user_id: userId, parent_id: parentId, title: title, description: description))
            .select("id,parent_id,title,description")
            .single()
            .execute()
            .value
        return Folder(id: row.id, parentId: row.parent_id, title: row.title, description: row.description)
    }

    // 제목/설명 변경. 형제 이름 중복 시 서버 유니크 인덱스가 오류 → 호출부 안내.
    func updateFolder(id: UUID, title: String, description: String?) async throws {
        struct Upd: Encodable { let title: String; let description: String? }
        try await client.from("folders")
            .update(Upd(title: title, description: description))
            .eq("id", value: id)
            .execute()
    }

    // 폴더 이동(부모 변경). 깊이 초과·순환은 서버 트리거가 거부 → throw.
    func reparentFolder(id: UUID, parentId: UUID?) async throws {
        struct Upd: Encodable { let parent_id: UUID? }
        try await client.from("folders")
            .update(Upd(parent_id: parentId))
            .eq("id", value: id)
            .execute()
    }

    // 빈 폴더만 삭제(호출부에서 자식/메모 0 확인). 자식 있으면 on delete restrict가 거부.
    func deleteFolder(id: UUID) async throws {
        try await client.from("folders")
            .delete()
            .eq("id", value: id)
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
        Memo(id: r.id, content: r.content, folderId: r.folder_id,
             embeddingModel: r.embedding_model,
             createdAt: parseDate(r.created_at), updatedAt: parseDate(r.updated_at),
             deletedAt: r.deleted_at.map { parseDate($0) },
             isPinned: r.is_pinned ?? false)
    }
}
