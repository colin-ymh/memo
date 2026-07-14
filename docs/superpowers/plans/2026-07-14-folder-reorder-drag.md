# 폴더 순서+뎁스 드래그 재정렬 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 폴더 관리 화면에서 폴더를 드래그해 형제 순서와 뎁스(parent)를 자유롭게 지정하고, 삽입선으로 시각 표시한다.

**Architecture:** 순서를 `folders.position`에 저장하고 앱 전체 정렬을 `(position, title)`로 바꾼다. 재정렬의 순수 수학(평탄화 → 갭+뎁스 → parent+index → position 정규화)을 SwiftUI와 분리한 `FolderReorder` 모듈로 빼서 유닛테스트로 검증한다. 관리 화면의 `.draggable/.dropDestination`을 커스텀 `DragGesture` + 삽입선 오버레이로 교체한다.

**Tech Stack:** Swift 6 / SwiftUI, Supabase(Postgres), XcodeGen(project.yml), XCTest.

## Global Constraints
- 최대 폴더 깊이 3단계 (`kMaxFolderDepth = 3`). 최상위 depth=1.
- 깊이/순환은 DB 트리거 `enforce_folder_tree`가 최종 방어. 클라는 UX 사전차단만.
- 폴더 변경은 "온라인 즉시 실행 후 `vm.load()`" 정책(오프라인 큐 대상 아님).
- 정렬 키는 어디서나 `(position asc, title asc)`.
- depth는 1-based. `MemoListViewModel.depth(of:)` 그대로 사용.
- 커밋 메시지 말미: `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>` / `Claude-Session: https://claude.ai/code/session_01YPKM3QY9Aak676y7MfU2ML`.

## File Structure
- Create `supabase/migrations/20260714000000_folder_position.sql` — position 컬럼 + backfill.
- Modify `ios/Memo/Models/Memo.swift` — `Folder.position`.
- Modify `ios/Memo/Services/MemoRepository.swift` — position decode/insert, 이동·정렬 저장 API.
- Modify `ios/Memo/Features/MemoList/MemoListViewModel.swift` — 정렬 키, `moveFolder`.
- Create `ios/Memo/Features/MemoList/FolderReorder.swift` — 순수 재정렬 로직.
- Create `ios/MemoTests/FolderReorderTests.swift` — 유닛테스트.
- Modify `ios/project.yml` — `MemoTests` 타깃 추가.
- Modify `ios/Memo/Features/Settings/CategoryManageView.swift` — 커스텀 드래그 + 삽입선.

---

### Task 1: DB 마이그레이션 — position 컬럼 + backfill

**Files:**
- Create: `supabase/migrations/20260714000000_folder_position.sql`

**Interfaces:**
- Produces: `public.folders.position int not null default 0`.

- [ ] **Step 1: 마이그레이션 SQL 작성**

```sql
-- folders에 형제 순서(position) 추가. 정렬은 (position, title).
-- 깊이/순환 트리거·RLS·FK와 직교(무결성 영향 없음).
alter table public.folders add column if not exists position int not null default 0;

-- 기존 행 backfill: 형제 그룹별 현재 title 순서를 position 0..n으로.
with ordered as (
    select id,
           row_number() over (
               partition by user_id, coalesce(parent_id, '00000000-0000-0000-0000-000000000000'::uuid)
               order by title
           ) - 1 as pos
    from public.folders
)
update public.folders f
set position = ordered.pos
from ordered
where f.id = ordered.id;
```

- [ ] **Step 2: 원격 적용**

Supabase MCP `apply_migration` (name: `folder_position`, 위 SQL). DB 변경이므로 적용 전 사용자 확인은 이미 받음(스펙 승인).

- [ ] **Step 3: 적용 검증**

`execute_sql`: `select column_name, data_type, is_nullable from information_schema.columns where table_name='folders' and column_name='position';`
Expected: `position | integer | NO`.
`select parent_id, title, position from public.folders order by parent_id nulls first, position;` — 형제별 0..n 확인.

- [ ] **Step 4: Commit**

```bash
git add supabase/migrations/20260714000000_folder_position.sql
git commit -m "feat(db): folders.position 추가 + title순 backfill"
```

---

### Task 2: Folder 모델 + repo position 반영

**Files:**
- Modify: `ios/Memo/Models/Memo.swift:63-68` (Folder)
- Modify: `ios/Memo/Services/MemoRepository.swift` (folders fetch/insert)

**Interfaces:**
- Consumes: Task 1의 `position` 컬럼.
- Produces: `Folder.position: Int`. repo가 fetch 시 position 디코드, createFolder 시 형제 말미 position 부여.

- [ ] **Step 1: Folder에 position 추가**

`ios/Memo/Models/Memo.swift` Folder를 아래로:

```swift
struct Folder: Identifiable, Codable, Sendable, Hashable {
    let id: UUID
    var parentId: UUID?
    var title: String
    var description: String?
    var position: Int = 0
}
```

CodingKeys가 명시돼 있으면 `case position` 추가. (파일 확인 후 snake/camel 매핑 기존 패턴 따를 것 — 다른 필드가 `parent_id`↔`parentId`를 어떻게 매핑하는지 그대로.)

- [ ] **Step 2: repo fetch에 position 포함**

`MemoRepository`의 folders select(예: `.select("id,parent_id,title,description")`)에 `position` 추가 → `.select("id,parent_id,title,description,position")`. 정확한 위치는 `grep -n "parent_id,title" ios/Memo/Services/MemoRepository.swift`로 찾아 수정.

- [ ] **Step 3: createFolder에 position 부여**

`createFolder`(insert) 시 같은 parent의 현재 최대 position+1을 넣는다. Insert payload struct에 `position: Int` 추가하고, 호출부(`MemoListViewModel.createFolder`)에서 `(vm 형제 최대 position)+1` 전달. 형제 없으면 0.

- [ ] **Step 4: 빌드 확인**

Run: `xcodebuild -project ios/Memo.xcodeproj -scheme Memo -destination 'generic/platform=iOS Simulator' build 2>&1 | grep -E "error:|BUILD SUCCEEDED"`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add ios/Memo/Models/Memo.swift ios/Memo/Services/MemoRepository.swift
git commit -m "feat(folder): Folder.position 모델·repo 반영"
```

---

### Task 3: 순수 재정렬 로직 + 테스트 타깃 (TDD 핵심)

**Files:**
- Create: `ios/Memo/Features/MemoList/FolderReorder.swift`
- Create: `ios/MemoTests/FolderReorderTests.swift`
- Modify: `ios/project.yml` (MemoTests 타깃)

**Interfaces:**
- Produces:
  - `struct FlatFolder: Equatable { let id: UUID; let parentId: UUID?; let depth: Int }`
  - `struct DropResolution: Equatable { let parentId: UUID?; let index: Int }`
  - `enum FolderReorder`:
    - `static func flatten(_ nodes: [(id: UUID, parentId: UUID?, depth: Int)]) -> [FlatFolder]`
    - `static func depthRange(flat: [FlatFolder], gapIndex: Int, subtreeHeight: Int, maxDepth: Int) -> ClosedRange<Int>`
    - `static func resolve(flat: [FlatFolder], gapIndex: Int, depth: Int) -> DropResolution`
  - `flat`은 **드래그 노드의 서브트리를 제외한** 평탄 배열(호출부가 제외 후 전달). `gapIndex`는 `0...flat.count`.

- [ ] **Step 1: project.yml에 MemoTests 타깃 추가**

`ios/project.yml`의 `targets:` 아래에 추가(기존 `Memo` 타깃 들여쓰기·형식에 맞춰):

```yaml
  MemoTests:
    type: bundle.unit-test
    platform: iOS
    sources: [MemoTests]
    dependencies:
      - target: Memo
    settings:
      base:
        GENERATE_INFOPLIST_FILE: YES
```

그리고 상단 `schemes`가 있으면 Memo 스킴 test에 MemoTests를 넣는다. 스킴 자동생성(xcodegen 기본)이면 생략. 이후:

Run: `cd ios && xcodegen generate`
Expected: `Created project at ...Memo.xcodeproj`

- [ ] **Step 2: 실패 테스트 작성**

`ios/MemoTests/FolderReorderTests.swift`:

```swift
import XCTest
@testable import Memo

final class FolderReorderTests: XCTestCase {
    // 트리(드래그 노드 제외 후 평탄): 개발(1) > [가챠맵(2), 메모(2)], 일상(1)
    // id를 알아보기 쉽게 상수로.
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
        // prev=메모(depth2) → 최대 depth(prev)+1=3, next=일상(depth1) → 최소 1.
        let range = FolderReorder.depthRange(flat: flat, gapIndex: 3, subtreeHeight: 1, maxDepth: 3)
        XCTAssertEqual(range, 1...3)
    }
    func test_depthRange_서브트리2면_최대뎁스감소() {
        // 드래그 노드가 자식 1단계 보유(subtreeHeight=2) → 그 노드가 depth d면 자식은 d+1.
        // d+ (2-1) <= 3 → d<=2. prev=메모(2)라 상한 min(3,2)=2.
        let range = FolderReorder.depthRange(flat: flat, gapIndex: 3, subtreeHeight: 2, maxDepth: 3)
        XCTAssertEqual(range, 1...2)
    }
}
```

- [ ] **Step 3: 실패 확인**

Run: `xcodebuild test -project ios/Memo.xcodeproj -scheme Memo -destination 'platform=iOS Simulator,name=iPhone 15 Pro' 2>&1 | grep -E "error:|Compiling|Test Suite|failed"`
Expected: 컴파일 실패(`FolderReorder`/`FlatFolder` 미정의).

- [ ] **Step 4: FolderReorder 구현**

`ios/Memo/Features/MemoList/FolderReorder.swift`:

```swift
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
```

- [ ] **Step 5: 통과 확인**

Run: `xcodebuild test -project ios/Memo.xcodeproj -scheme Memo -destination 'platform=iOS Simulator,name=iPhone 15 Pro' 2>&1 | grep -E "Test Suite 'FolderReorderTests'|passed|failed"`
Expected: `Test Suite 'FolderReorderTests' passed`. 6 테스트 통과.

> 만약 `test_얕게_최상위_일상앞`가 index=1 아닌 값이면: prev=메모(depth2)에서 depth1까지 올라가면 anc=개발(depth1), parentId=nil, siblings=[개발,일상], ancIdx=0 → index 1. 로직대로면 통과.

- [ ] **Step 6: Commit**

```bash
git add ios/Memo/Features/MemoList/FolderReorder.swift ios/MemoTests/FolderReorderTests.swift ios/project.yml
git commit -m "feat(folder): 재정렬 순수 로직 + 유닛테스트 타깃"
```

---

### Task 4: repo 이동·정렬 저장 API

**Files:**
- Modify: `ios/Memo/Services/MemoRepository.swift`
- Modify: `ios/Memo/Services/MemoRepository.swift` (protocol 선언부 ~line 24 부근)

**Interfaces:**
- Produces:
  - `func updateFolderParentAndPosition(id: UUID, parentId: UUID?, position: Int) async throws`
  - `func setFolderPositions(_ items: [(id: UUID, position: Int)]) async throws`

- [ ] **Step 1: 프로토콜에 선언 추가**

`MemoRepository` 프로토콜(파일 상단, `func reparentFolder` 근처)에:

```swift
    func updateFolderParentAndPosition(id: UUID, parentId: UUID?, position: Int) async throws
    func setFolderPositions(_ items: [(id: UUID, position: Int)]) async throws
```

- [ ] **Step 2: 구현 추가**

`reparentFolder` 구현 아래에:

```swift
    func updateFolderParentAndPosition(id: UUID, parentId: UUID?, position: Int) async throws {
        struct Upd: Encodable { let parent_id: UUID?; let position: Int }
        try await client.from("folders")
            .update(Upd(parent_id: parentId, position: position))
            .eq("id", value: id)
            .execute()
    }

    func setFolderPositions(_ items: [(id: UUID, position: Int)]) async throws {
        struct Upd: Encodable { let position: Int }
        for it in items {
            try await client.from("folders")
                .update(Upd(position: it.position))
                .eq("id", value: it.id)
                .execute()
        }
    }
```

- [ ] **Step 3: 빌드 확인**

Run: `xcodebuild -project ios/Memo.xcodeproj -scheme Memo -destination 'generic/platform=iOS Simulator' build 2>&1 | grep -E "error:|BUILD SUCCEEDED"`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 4: Commit**

```bash
git add ios/Memo/Services/MemoRepository.swift
git commit -m "feat(folder): repo 이동+순서 저장 API"
```

---

### Task 5: VM 정렬 키 + moveFolder

**Files:**
- Modify: `ios/Memo/Features/MemoList/MemoListViewModel.swift:90-91` (subfolders)
- Modify: `ios/Memo/Features/MemoList/MemoListViewModel.swift:173` (allFolders 정렬)
- Modify: `ios/Memo/Features/MemoList/MemoListViewModel.swift` (moveFolder 추가, reparentFolder 근처)

**Interfaces:**
- Consumes: Task 3 `FolderReorder`, Task 4 repo API.
- Produces: `func moveFolder(id: UUID, toParent: UUID?, index: Int) async -> Bool`. `subtreeHeight(of:) -> Int` 헬퍼.

- [ ] **Step 1: 정렬 키 교체**

`subfolders(of:)`:

```swift
    func subfolders(of parent: UUID?) -> [Folder] {
        allFolders.filter { $0.parentId == parent }
            .sorted { ($0.position, $0.title) < ($1.position, $1.title) }
    }
```

`allFolders = ff.sorted { $0.title < $1.title }` →

```swift
        allFolders = ff.sorted { ($0.position, $0.title) < ($1.position, $1.title) }
```

(Swift 튜플 비교는 Comparable 자동. `(Int,String)` OK.)

- [ ] **Step 2: subtreeHeight 헬퍼 추가**

`descendantIds(of:)` 근처:

```swift
    // 이 폴더 서브트리의 높이(자기=1). 이동 시 뎁스 상한 계산용.
    func subtreeHeight(of id: UUID) -> Int {
        let kids = allFolders.filter { $0.parentId == id }
        if kids.isEmpty { return 1 }
        return 1 + (kids.map { subtreeHeight(of: $0.id) }.max() ?? 0)
    }
```

- [ ] **Step 3: moveFolder 추가**

`reparentFolder` 아래:

```swift
    // 드래그 재정렬 확정: id를 toParent의 index 위치로. 낙관적 반영 후 저장, 실패 시 load로 롤백.
    func moveFolder(id: UUID, toParent: UUID?, index: Int) async -> Bool {
        let oldParent = foldersById[id]?.parentId
        // 새 부모의 자식 목록(자기 제외) 만들고 index에 삽입.
        var newSiblings = subfolders(of: toParent).map { $0.id }.filter { $0 != id }
        let clamped = max(0, min(index, newSiblings.count))
        newSiblings.insert(id, at: clamped)

        do {
            // 이동 노드: parent + position(=삽입 위치).
            try await repo.updateFolderParentAndPosition(id: id, parentId: toParent, position: clamped)
            // 새 부모 그룹 position 0..n 정규화.
            try await repo.setFolderPositions(newSiblings.enumerated().map { ($1, $0) })
            // 부모가 바뀌었으면 옛 부모 그룹도 정규화.
            if oldParent != toParent {
                let oldSiblings = subfolders(of: oldParent).map { $0.id }.filter { $0 != id }
                try await repo.setFolderPositions(oldSiblings.enumerated().map { ($1, $0) })
            }
            await load()
            return true
        } catch {
            errorText = error.localizedDescription
            await load()
            return false
        }
    }
```

- [ ] **Step 4: 빌드 확인**

Run: `xcodebuild -project ios/Memo.xcodeproj -scheme Memo -destination 'generic/platform=iOS Simulator' build 2>&1 | grep -E "error:|BUILD SUCCEEDED"`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 5: Commit**

```bash
git add ios/Memo/Features/MemoList/MemoListViewModel.swift
git commit -m "feat(folder): VM 정렬 키(position) + moveFolder"
```

---

### Task 6: 커스텀 드래그 + 삽입선 UI

**Files:**
- Modify: `ios/Memo/Features/Settings/CategoryManageView.swift`

**Interfaces:**
- Consumes: Task 3 `FolderReorder`, Task 5 `vm.moveFolder`, `vm.subtreeHeight`, `vm.descendantIds`.

이 태스크는 유닛테스트 불가(제스처). 각 스텝 후 빌드 + 최종 시뮬레이터 수동 드래그로 검증.

- [ ] **Step 1: 행 지오메트리 수집 구조 준비**

`FolderManageView`에 상태 추가:

```swift
    @State private var draggingId: UUID?
    @State private var dragOffset: CGSize = .zero
    @State private var rowFrames: [UUID: CGRect] = [:]   // coord space "tree" 기준
    @State private var dropGapIndex: Int = 0             // 현재 삽입 갭
    @State private var dropDepth: Int = 1                // 현재 목표 뎁스
```

행 프레임 수집: 각 rowView에 `.background(GeometryReader{ ... preference })`로 `rowFrames[id]` 채움. `coordinateSpace(name: "tree")`를 ScrollView 콘텐츠 VStack에 지정.

```swift
// VStack에:
.coordinateSpace(name: "tree")
// rowView 배경에:
.background(GeometryReader { g in
    Color.clear.onAppear { rowFrames[f.id] = g.frame(in: .named("tree")) }
        .onChange(of: g.frame(in: .named("tree"))) { _, nv in rowFrames[f.id] = nv }
})
```

- [ ] **Step 2: 기존 .draggable/.dropDestination 제거**

rowView·rootDropRow에서 `.draggable(...)`, `.dropDestination(...)`, `rootTargeted`/`dropTarget` 관련 배경을 제거한다. (rootDropRow 자체는 삭제 — 최상위 이동은 이제 삽입선 depth=1로 표현.)

- [ ] **Step 3: LongPress→Drag 제스처 부착**

각 rowView에:

```swift
.opacity(draggingId == f.id ? 0.35 : 1)
.gesture(
    LongPressGesture(minimumDuration: 0.3)
        .sequenced(before: DragGesture(coordinateSpace: .named("tree")))
        .onChanged { value in
            switch value {
            case .second(true, let drag?):
                if draggingId == nil { draggingId = f.id }
                updateDrop(fingerY: drag.location.y, fingerX: drag.location.x)
            default: break
            }
        }
        .onEnded { _ in commitDrop() }
)
```

- [ ] **Step 4: updateDrop / commitDrop 구현**

`FolderManageView`에:

```swift
// 드래그 서브트리를 제외한 평탄 배열(FolderReorder 입력).
private func flatExcludingDragged() -> [FlatFolder] {
    guard let dragging = draggingId else { return [] }
    let excluded = vm.descendantIds(of: dragging).union([dragging])
    return vm.orderedTree()
        .filter { !excluded.contains($0.folder.id) }
        .map { FlatFolder(id: $0.folder.id, parentId: $0.folder.parentId, depth: $0.depth + 1) }
    // orderedTree depth는 0-based → +1로 1-based 맞춤.
}

private func updateDrop(fingerY: CGFloat, fingerX: CGFloat) {
    let flat = flatExcludingDragged()
    // 갭 인덱스: 각 행 midY와 비교해 손가락이 몇 번째 행 경계인지.
    var gap = flat.count
    for (i, ff) in flat.enumerated() {
        if let r = rowFrames[ff.id], fingerY < r.midY { gap = i; break }
    }
    // 뎁스: x를 들여쓰기 폭(=Space.x4*단계, 기존 rowView indent와 동일 계수)으로 나눠 레벨화.
    let indentUnit: CGFloat = 16                 // rowView의 depth*16과 동일
    let baseX: CGFloat = 20                       // 최상위 콘텐츠 좌측 여백 근사
    let rawDepth = Int(((fingerX - baseX) / indentUnit).rounded()) + 1
    let sub = vm.subtreeHeight(of: draggingId!)
    let range = FolderReorder.depthRange(flat: flat, gapIndex: gap, subtreeHeight: sub, maxDepth: kMaxFolderDepth)
    dropGapIndex = gap
    dropDepth = min(max(rawDepth, range.lowerBound), range.upperBound)
}

private func commitDrop() {
    defer { draggingId = nil }
    guard let dragging = draggingId else { return }
    let flat = flatExcludingDragged()
    let res = FolderReorder.resolve(flat: flat, gapIndex: dropGapIndex, depth: dropDepth)
    Task { busy = true; _ = await vm.moveFolder(id: dragging, toParent: res.parentId, index: res.index); busy = false }
}
```

- [ ] **Step 5: 삽입선 오버레이**

ScrollView 콘텐츠에 `.overlay`로 삽입선. 갭 y = (위 행 maxY + 아래 행 minY)/2 또는 끝. x 들여쓰기 = `dropDepth`:

```swift
// VStack .overlay(alignment: .topLeading):
.overlay(alignment: .topLeading) {
    if draggingId != nil {
        let flat = flatExcludingDragged()
        let y: CGFloat = {
            if dropGapIndex <= 0 { return rowFrames[flat.first?.id ?? UUID()]?.minY ?? 0 }
            if dropGapIndex >= flat.count { return rowFrames[flat.last?.id ?? UUID()]?.maxY ?? 0 }
            let above = rowFrames[flat[dropGapIndex-1].id]?.maxY ?? 0
            let below = rowFrames[flat[dropGapIndex].id]?.minY ?? 0
            return (above + below) / 2
        }()
        let leading = 20 + CGFloat(dropDepth - 1) * 16
        Capsule().fill(AppColor.accent).frame(height: 3)
            .padding(.leading, leading).padding(.trailing, Space.x3)
            .offset(y: y - 1.5)
            .allowsHitTesting(false)
    }
}
```

- [ ] **Step 6: 빌드 확인**

Run: `xcodebuild -project ios/Memo.xcodeproj -scheme Memo -destination 'generic/platform=iOS Simulator' build 2>&1 | grep -E "error:|BUILD SUCCEEDED"`
Expected: `** BUILD SUCCEEDED **`

- [ ] **Step 7: 시뮬레이터 수동 검증 (필수)**

Debug 빌드를 부팅된 시뮬레이터에 설치·실행:

```bash
xcodebuild -project ios/Memo.xcodeproj -scheme Memo -configuration Debug \
  -destination 'id=<BOOTED_UDID>' -derivedDataPath ios/build/dd build
APP=$(find ios/build/dd -type d -name Memo.app -path "*iphonesimulator*" | head -1)
xcrun simctl install <BOOTED_UDID> "$APP"
xcrun simctl launch <BOOTED_UDID> com.duovelop.memo
```

사용자에게 드래그 검증 요청(에이전트는 드래그 제스처 재현 불가):
- 서류를 메모/일상 사이로 끌 때 x에 따라 최상위/개발자식/메모안 3케이스 삽입선·결과 정확한지
- 앱 재실행 후 순서 유지되는지

- [ ] **Step 8: Commit**

```bash
git add ios/Memo/Features/Settings/CategoryManageView.swift
git commit -m "feat(folder): 순서+뎁스 커스텀 드래그 + 삽입선"
```

---

### Task 7: 빌드번호 + TestFlight 배포

**Files:**
- Modify: `ios/project.yml` (CURRENT_PROJECT_VERSION)

전제: Task 6 Step 7 수동 검증 통과. (미검증 배포 금지 — 앞선 build 10 전례.)

- [ ] **Step 1: 빌드번호 bump**

`ios/project.yml` `CURRENT_PROJECT_VERSION: "11"` → `"12"`, 이어서 `cd ios && xcodegen generate`.

- [ ] **Step 2: 커밋+푸시**

```bash
git add ios/project.yml
git commit -m "chore(ios): 빌드번호 12"
git push
```

- [ ] **Step 3: 아카이브→익스포트→업로드**

배포 절차는 메모리 `testflight-deploy.md` 참고:
```bash
xcodebuild -project ios/Memo.xcodeproj -scheme Memo -configuration Release -destination 'generic/platform=iOS' -archivePath ios/build/Memo.xcarchive clean archive
xcodebuild -exportArchive -archivePath ios/build/Memo.xcarchive -exportOptionsPlist ios/exportOptions.plist -exportPath ios/build/export
xcrun altool --upload-app -f ios/build/export/memo.ipa -t ios --apiKey RX24ST7S2T --apiIssuer 9da8dbfa-4410-4d03-9140-39cdd5546308
```
Expected: `UPLOAD SUCCEEDED with no errors`.

- [ ] **Step 4: Slack 보고**

`.claude/pending-report.json`에 plan 채널 1건(순서+뎁스 드래그 완료 + 빌드 12).

---

## Self-Review 결과
- **스펙 커버리지**: 모델/마이그레이션(T1-2), 앱 전체 정렬(T5 Step1), 커스텀 드래그+뎁스(T6), 삽입선(T6 Step5), 저장/롤백(T5 Step3), 순환·깊이 방어(depthRange+트리거), 검증기준(T6 Step7) — 모두 태스크 있음.
- **플레이스홀더**: 없음(코드·SQL·명령 실물).
- **타입 일관성**: `FlatFolder`/`DropResolution`/`FolderReorder.resolve|depthRange`, `moveFolder(id:toParent:index:)`, repo 2개 API 명이 T3→T5→T6에서 일치.
- **주의**: T6의 좌표 상수(indentUnit 16, baseX 20)는 실제 rowView 들여쓰기·패딩과 맞춰 수동 튜닝 필요(Step7에서 조정). rowView 기존 indent 계수(`depth*16`)와 동일해야 삽입선이 정렬됨.
