import Foundation

// 드래그 재정렬의 순수 로직(SwiftUI 무관). 평탄 배열은 "드래그 서브트리를 제외한"
// 현재 보이는 순서. depth는 1-based(최상위=1).
struct FlatFolder: Equatable {
    let id: UUID
    let parentId: UUID?
    let depth: Int
}

struct DropResolution: Equatable {
    let parentId: UUID?   // 드롭 후 부모(nil=최상위)
    let index: Int        // 그 부모의 자식들 안에서의 0-based 위치
}

// 대상 행 기준 세로 드롭 구역. 위=앞 형제, 가운데=자식(안), 아래=뒤 형제.
enum DropZone { case before, into, after }

enum FolderReorder {

    // into(자식으로 넣기) 가능 여부. flat은 드래그+후손을 제외하므로 자기/후손 대상은 자동 배제.
    // 대상 depth + 드래그 서브트리 높이 ≤ maxDepth 여야 함.
    static func canNest(flat: [FlatFolder], targetId: UUID, subtreeHeight: Int, maxDepth: Int) -> Bool {
        guard let target = flat.first(where: { $0.id == targetId }) else { return false }
        return target.depth + subtreeHeight <= maxDepth
    }

    // (대상 행, 구역) → (parentId, index). index는 드래그 제외 형제 공간 기준.
    // mokjang 참고 시맨틱: into=자식 맨 뒤, after+대상이_자식보유=대상의 첫 자식(안 맨 위), 그 외 형제.
    static func resolve(flat: [FlatFolder], targetId: UUID, zone: DropZone) -> DropResolution? {
        guard let target = flat.first(where: { $0.id == targetId }) else { return nil }
        let children = flat.filter { $0.parentId == targetId }
        switch zone {
        case .into:
            return DropResolution(parentId: targetId, index: children.count)   // 자식 맨 뒤
        case .before:
            let sibs = flat.filter { $0.parentId == target.parentId }
            return DropResolution(parentId: target.parentId, index: sibs.firstIndex { $0.id == targetId } ?? 0)
        case .after:
            if !children.isEmpty {
                return DropResolution(parentId: targetId, index: 0)            // 자식 있으면 그 안 맨 위
            }
            let sibs = flat.filter { $0.parentId == target.parentId }
            let idx = sibs.firstIndex { $0.id == targetId } ?? 0
            return DropResolution(parentId: target.parentId, index: idx + 1)
        }
    }
}
