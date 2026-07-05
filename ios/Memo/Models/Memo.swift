import Foundation

// DB 스키마(public.memos / public.categories)와 대응. Sendable로 동시성 안전.
struct Memo: Identifiable, Codable, Sendable, Hashable {
    let id: UUID
    var content: String
    var categoryId: UUID?
    var embeddingModel: String?   // nil이면 아직 분류/임베딩 전(= 분류 중)
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?

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

struct Category: Identifiable, Codable, Sendable, Hashable {
    let id: UUID
    var name: String
    var createdByAi: Bool
}
