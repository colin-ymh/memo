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
    // 카드/목록 표시용이라 마크다운 기호는 스트립(상세는 content 원문을 풀 렌더).
    var title: String {
        (content.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? "").markdownStripped
    }
    var preview: String {
        let parts = content.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
        return (parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespacesAndNewlines) : "").markdownStripped
    }
}

extension String {
    // 카드 프리뷰용 경량 마크다운 기호 제거(렌더가 아니라 표시 정리). 상세 렌더엔 영향 없음.
    var markdownStripped: String {
        var s = self
        // 줄머리 블록 기호(제목#, 인용>, 불릿-*+, 번호1.) 제거
        s = s.replacingOccurrences(
            of: #"(?m)^\s{0,3}(#{1,6}\s+|>\s?|[-*+]\s+|\d+\.\s+)"#,
            with: "", options: .regularExpression)
        // 인라인 강조/코드 기호 제거
        s = s.replacingOccurrences(of: #"[*_`~]"#, with: "", options: .regularExpression)
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// 관련 메모(recall) — related_memos RPC 결과.
struct RelatedMemo: Identifiable, Sendable, Hashable {
    let id: UUID
    let content: String
    let categoryId: UUID?
    let similarity: Double

    var title: String {
        (content.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? "").markdownStripped
    }
    var snippet: String {
        let parts = content.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true)
        return (parts.count > 1 ? String(parts[1]) : "").trimmingCharacters(in: .whitespacesAndNewlines).markdownStripped
    }
}

struct Category: Identifiable, Codable, Sendable, Hashable {
    let id: UUID
    var name: String
    var createdByAi: Bool
}
