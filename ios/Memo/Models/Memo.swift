import Foundation

// DB 스키마(public.memos / public.folders)와 대응. Sendable로 동시성 안전.
struct Memo: Identifiable, Codable, Sendable, Hashable {
    let id: UUID
    var content: String
    var folderId: UUID?           // nil이면 미분류
    var embeddingModel: String?   // nil이면 아직 분류/임베딩 전(= 분류 중)
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?
    var isPinned: Bool = false

    // 분류/임베딩 완료 여부(관련메모 recall 가능 여부와 연결)
    var isClassified: Bool { embeddingModel != nil }

    // content 첫 줄 = 제목, 나머지 = 미리보기 (스키마엔 content 단일)
    var title: String {
        content.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
    }
    var preview: String {
        let parts = content.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
        return parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : ""
    }
}

// 커스텀 Decodable(extension이라 memberwise init 유지). isPinned는 구 캐시 호환 위해
// decodeIfPresent — 이전에 저장된 스냅샷엔 키가 없어 keyNotFound 나므로.
extension Memo {
    enum CodingKeys: String, CodingKey {
        case id, content, folderId, embeddingModel, createdAt, updatedAt, deletedAt, isPinned
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        content = try c.decode(String.self, forKey: .content)
        folderId = try c.decodeIfPresent(UUID.self, forKey: .folderId)
        embeddingModel = try c.decodeIfPresent(String.self, forKey: .embeddingModel)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        deletedAt = try c.decodeIfPresent(Date.self, forKey: .deletedAt)
        isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
    }
}

// 관련 메모(recall) — related_memos RPC 결과.
struct RelatedMemo: Identifiable, Sendable, Hashable {
    let id: UUID
    let content: String
    let folderId: UUID?
    let similarity: Double

    var title: String {
        content.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? ""
    }
    var snippet: String {
        let parts = content.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
        return (parts.count > 1 ? String(parts[1]) : "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// public.folders와 대응. 자기참조 트리(최대 3뎁스). parentId nil = 최상위.
struct Folder: Identifiable, Codable, Sendable, Hashable {
    let id: UUID
    var parentId: UUID?
    var title: String
    var description: String?
    var position: Int = 0
}
