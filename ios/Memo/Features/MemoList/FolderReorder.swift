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

enum FolderReorder {

    // 갭에서 허용되는 뎁스 범위. 위 행 있으면 최대 = depth(prev)+1, 없으면 1.
    // 최소 = 다음 행 depth(없으면 1). 드래그 서브트리 높이를 더해 maxDepth 초과 레벨은 상한에서 제거.
    static func depthRange(flat: [FlatFolder], gapIndex: Int,
                           subtreeHeight: Int, maxDepth: Int) -> ClosedRange<Int> {
        let prev = gapIndex > 0 ? flat[gapIndex - 1] : nil
        let next = gapIndex < flat.count ? flat[gapIndex] : nil
        let hardMax = prev.map { $0.depth + 1 } ?? 1
        // 서브트리(높이 h)를 d에 놓으면 가장 깊은 자손 = d + (h-1) ≤ maxDepth → d ≤ maxDepth-(h-1)
        let capBySubtree = maxDepth - (subtreeHeight - 1)
        let upper = max(1, min(hardMax, capBySubtree))
        let lower = next?.depth ?? 1
        let low = min(lower, upper)
        return low...upper
    }

    // (갭, 뎁스) → (parentId, index). 아웃라이너 표준 해석.
    static func resolve(flat: [FlatFolder], gapIndex: Int, depth: Int) -> DropResolution {
        guard let prev = gapIndex > 0 ? flat[gapIndex - 1] : nil else {
            // 맨 앞 → 최상위 첫 자리.
            return DropResolution(parentId: nil, index: 0)
        }
        if depth == prev.depth + 1 {
            // prev의 첫 자식.
            return DropResolution(parentId: prev.id, index: 0)
        }
        // prev의 조상 체인을 올라가 depth 레벨의 노드(anc)를 찾고, 그 부모의 자식 목록에서 anc 다음.
        var anc: FlatFolder = prev
        while anc.depth > depth {
            guard let p = flat.first(where: { $0.id == anc.parentId }) else { break }
            anc = p
        }
        let parentId = anc.parentId          // depth-1 부모(최상위면 nil)
        let siblings = flat.filter { $0.parentId == parentId }
        let ancIdx = siblings.firstIndex(where: { $0.id == anc.id }) ?? (siblings.count - 1)
        return DropResolution(parentId: parentId, index: ancIdx + 1)
    }
}
