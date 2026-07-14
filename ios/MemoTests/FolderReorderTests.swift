import XCTest
@testable import Memo

final class FolderReorderTests: XCTestCase {
    // 트리(드래그 노드 제외 후 평탄): 개발(1) > [가챠맵(2), 메모(2)], 일상(1)
    let dev = UUID(); let gacha = UUID(); let memoF = UUID(); let daily = UUID()
    var flat: [FlatFolder] {
        [FlatFolder(id: dev,    parentId: nil,  depth: 1),
         FlatFolder(id: gacha,  parentId: dev,  depth: 2),
         FlatFolder(id: memoF,  parentId: dev,  depth: 2),
         FlatFolder(id: daily,  parentId: nil,  depth: 1)]
    }
    // 메모와 일상 사이 갭 = index 3.

    func test_깊게_메모안_자식() {
        let r = FolderReorder.resolve(flat: flat, gapIndex: 3, depth: 3)
        XCTAssertEqual(r, DropResolution(parentId: memoF, index: 0))
    }
    func test_중간_개발_마지막자식() {
        let r = FolderReorder.resolve(flat: flat, gapIndex: 3, depth: 2)
        XCTAssertEqual(r, DropResolution(parentId: dev, index: 2)) // 가챠맵,메모 다음
    }
    func test_얕게_최상위_일상앞() {
        let r = FolderReorder.resolve(flat: flat, gapIndex: 3, depth: 1)
        XCTAssertEqual(r, DropResolution(parentId: nil, index: 1)) // 개발 다음, 일상 앞
    }
    func test_맨앞_최상위_index0() {
        let r = FolderReorder.resolve(flat: flat, gapIndex: 0, depth: 1)
        XCTAssertEqual(r, DropResolution(parentId: nil, index: 0))
    }
    func test_depthRange_메모일상사이_서브트리1_최대3() {
        let range = FolderReorder.depthRange(flat: flat, gapIndex: 3, subtreeHeight: 1, maxDepth: 3)
        XCTAssertEqual(range, 1...3)
    }
    func test_depthRange_서브트리2면_최대뎁스감소() {
        let range = FolderReorder.depthRange(flat: flat, gapIndex: 3, subtreeHeight: 2, maxDepth: 3)
        XCTAssertEqual(range, 1...2)
    }
}
