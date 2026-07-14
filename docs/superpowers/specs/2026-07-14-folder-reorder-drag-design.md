# 폴더 순서+뎁스 드래그 재정렬 — 설계

상태: 확정 · 분류: 🛠️ 개발 · 관련: `ios/Memo/Features/Settings/CategoryManageView.swift`, `supabase/migrations/20260709000000_folder_tree.sql`

## 목적
폴더 관리 화면에서 폴더를 드래그해 **형제 순서(order)와 뎁스(parent)를 자유롭게** 지정한다.
한 번의 드래그로 "행 사이 갭(세로 위치)"으로 순서를, "가로 들여쓰기(손가락 x)"로 뎁스를 정한다.
Notion/Files 사이드바 방식. 지정한 순서는 앱 전체(드로어·작성 피커)에 동일 반영.

### 대표 케이스 (서류를 메모/일상 사이로)
현재 트리: `개발 > [가챠맵, 메모]`, `일상`, `서류`.
메모와 일상 사이 갭에서 손가락 x에 따라:
- 얕게 → 서류가 **최상위**, 일상 위 순서로
- 중간 → 서류가 **개발의 마지막 자식**(가챠맵·메모 다음)
- 깊게 → 서류가 **메모 안** 자식으로

## 비목표 (YAGNI)
- 여러 폴더 동시 드래그, 멀티선택
- 애니메이션 물리 튜닝 과잉 (기본 스냅/이징만)
- 메모(폴더 아님) 드래그 이동 — 이번 범위 아님

## 1. 데이터 모델 / 마이그레이션
- `public.folders`에 `position int not null default 0` 추가.
- 정렬 키: `(position asc, title asc)` — position 동률 시 title 타이브레이크.
- 신규 마이그레이션 `supabase/migrations/20260714000000_folder_position.sql`:
  - `alter table public.folders add column position int not null default 0;`
  - 기존 행 backfill: 형제 그룹별 현재 title 순서를 position 0..n으로.
    `row_number() over (partition by user_id, coalesce(parent_id, sentinel) order by title) - 1`.
- 트리거(`enforce_folder_tree`)·RLS·FK는 그대로. position은 무결성과 직교(깊이/순환은 트리거가 계속 방어).
- iOS `Folder` 모델에 `var position: Int` 추가(Codable 키 `position`). repo insert 시 형제 말미 position 부여.

## 2. 정렬 반영 (앱 전체)
- `MemoListViewModel.subfolders(of:)`: `sorted { ($0.position,$0.title) < ($1.position,$1.title) }`.
- `orderedTree()`·드로어·작성 피커는 subfolders를 쓰므로 자동 반영.
- `allFolders` 로드 정렬도 동일 키로.

## 3. 인터랙션 (커스텀 제스처)
현재 `.draggable`/`.dropDestination`(행 단위 reparent만)으로는 "갭 삽입 + 가로 뎁스"를 표현 못 함 → **커스텀 드래그로 교체**.

- 트리를 `orderedTree()`로 평탄화한 행 배열로 렌더(각 행: id, depth, y범위 알고 있음).
- 롱프레스로 행 집어듦(`draggingId`). 드래그 중 원본 행은 자리 유지 + 들뜬 스타일(투명도/그림자).
- **세로(y)** → 삽입 갭 인덱스(행 사이). 자기 자신·자기 서브트리 위로는 삽입 불가(제외).
- **가로(x)** → 목표 뎁스. 갭에서 허용 뎁스 범위를 계산해 x를 가장 가까운 유효 레벨로 스냅.
  - 허용 범위: 위 행 기준 최대 = `depth(prevRow)+1`(그 행의 자식), 최소 = 다음 행 뎁스(또는 최상위=1).
  - 뎁스→parent 해석: prevRow에서 조상 체인을 올라가 `depth==목표-1`인 노드를 parent로. (아웃라이너 표준 알고리즘)
  - 뎁스 상한: 드래그 노드의 **서브트리 높이**를 더해 3 초과하는 레벨은 후보에서 제외(삽입선이 그 레벨로 안 감). 트리거가 최종 방어.
- 뗄 때 유효하면 `(parentId, position)` 확정 → 저장. 무효면 취소(원위치).

## 4. 저장 로직
- `MemoListViewModel.moveFolder(id:toParent:position:)`:
  1. 로컬 트리 갱신(낙관적) — parent_id·position 반영, 대상 형제 그룹 position 0..n 정규화.
  2. repo 호출: 이동 노드 parent_id+position 업데이트 + 영향받은 형제 그룹 position 일괄 업데이트.
  3. 실패 시 `errorText` + `load()`로 롤백.
- repo(`MemoRepository`): `updateFolderParentAndPosition(id:parentId:position:)`, `setFolderPositions([(id,Int)])`. 소규모(N 작음) 순차 업데이트 허용. parent_id 변경 시 트리거 검증 통과 전제.
- 기존 `reparentFolder`/`canReparent`는 유지하되, canReparent 로직(순환·깊이)을 뎁스 후보 계산에서 재사용.

## 5. 시각 표시
- **삽입선**: 목표 갭 y에 가로선(accent), x는 목표 뎁스만큼 들여쓰기. 드래그 중 실시간 이동.
- **드래그 행**: 살짝 확대/그림자, 손가락 따라감(또는 원행 자리표시 + 플로팅 프리뷰).
- 유효하지 않은 위치에선 삽입선 숨김 또는 회색.

## 6. 리스크
- 커스텀 히트테스트·스냅 튜닝 필요(방금 고친 것보다 복잡).
- **검증**: 에이전트가 드래그 제스처 재현 불가 → 시뮬레이터/실기기 실제 드래그로만 확인. 빌드 성공 ≠ 검증.
- 오프라인: 폴더 변경은 기존과 동일 "온라인 즉시 실행" 정책(오프라인 큐 대상 아님).

## 7. 검증 기준
- 대표 3케이스가 삽입선 뎁스대로 정확히 반영.
- 순서가 드로어·작성 피커에도 동일 반영.
- 3단계 초과/순환 이동은 삽입선이 막고, 우회 시 트리거가 거부.
- 앱 재실행 후 순서 유지(서버 저장 확인).
