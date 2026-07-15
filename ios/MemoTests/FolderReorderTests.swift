import XCTest
@testable import Memo

final class FolderReorderTests: XCTestCase {
    // 트리: 개발(1) > [가챠맵(2), 메모(2)], 일상(1)
    let dev = UUID(); let gacha = UUID(); let memoF = UUID(); let daily = UUID()

    // 드래그 노드(서류 등, 배열 밖)를 제외한 평탄 배열.
    var flat: [FlatFolder] {
        [FlatFolder(id: dev,   parentId: nil, depth: 1),
         FlatFolder(id: gacha, parentId: dev, depth: 2),
         FlatFolder(id: memoF, parentId: dev, depth: 2),
         FlatFolder(id: daily, parentId: nil, depth: 1)]
    }

    // into: 대상(자식 없음)의 자식 맨 뒤 = index 0
    func test_into_메모_자식() {
        XCTAssertEqual(FolderReorder.resolve(flat: flat, targetId: memoF, zone: .into),
                       DropResolution(parentId: memoF, index: 0))
    }
    // into: 대상(자식 2개)의 자식 맨 뒤 = index 2
    func test_into_개발_자식맨뒤() {
        XCTAssertEqual(FolderReorder.resolve(flat: flat, targetId: dev, zone: .into),
                       DropResolution(parentId: dev, index: 2))
    }
    // after: 대상(자식 없음) → 형제로 뒤
    func test_after_메모_개발_마지막자식() {
        XCTAssertEqual(FolderReorder.resolve(flat: flat, targetId: memoF, zone: .after),
                       DropResolution(parentId: dev, index: 2)) // 가챠맵,메모 다음
    }
    // after: 대상(자식 보유) → 그 안 첫 자식(맨 위)
    func test_after_개발_자식첫자리() {
        XCTAssertEqual(FolderReorder.resolve(flat: flat, targetId: dev, zone: .after),
                       DropResolution(parentId: dev, index: 0))
    }
    func test_before_일상_최상위() {
        XCTAssertEqual(FolderReorder.resolve(flat: flat, targetId: daily, zone: .before),
                       DropResolution(parentId: nil, index: 1)) // 개발 다음, 일상 앞
    }
    func test_before_개발_맨앞() {
        XCTAssertEqual(FolderReorder.resolve(flat: flat, targetId: dev, zone: .before),
                       DropResolution(parentId: nil, index: 0))
    }

    // 자기 형제 그룹 안에서 이동 — index 공간 정합(오프바이원 방지).
    // 가챠맵을 드래그하면 flat에서 가챠맵 제외 → [개발, 메모(2), 일상].
    func test_within_group_가챠맵을_메모뒤로() {
        let flatNoGacha = [FlatFolder(id: dev,   parentId: nil, depth: 1),
                           FlatFolder(id: memoF, parentId: dev, depth: 2),
                           FlatFolder(id: daily, parentId: nil, depth: 1)]
        // 메모 .after → 개발 자식 [메모]에서 메모(idx0) 다음 = 1
        XCTAssertEqual(FolderReorder.resolve(flat: flatNoGacha, targetId: memoF, zone: .after),
                       DropResolution(parentId: dev, index: 1))
    }

    // canNest: 대상 depth + 서브트리 높이 ≤ maxDepth(3)
    func test_canNest_메모_단일() {
        XCTAssertTrue(FolderReorder.canNest(flat: flat, targetId: memoF, subtreeHeight: 1, maxDepth: 3)) // 2+1=3
    }
    func test_canNest_메모_서브트리2_불가() {
        XCTAssertFalse(FolderReorder.canNest(flat: flat, targetId: memoF, subtreeHeight: 2, maxDepth: 3)) // 2+2=4
    }
    func test_canNest_개발_가능() {
        XCTAssertTrue(FolderReorder.canNest(flat: flat, targetId: dev, subtreeHeight: 1, maxDepth: 3)) // 1+1=2
    }
    // flat에 없는 대상(자기/후손) → nest 불가
    func test_canNest_대상없음_불가() {
        XCTAssertFalse(FolderReorder.canNest(flat: flat, targetId: UUID(), subtreeHeight: 1, maxDepth: 3))
    }
}
