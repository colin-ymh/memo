# 설계: 다크모드 · 메모 검색 · i18n

상태: 확정 · 분류: 개발 · 날짜: 2026-07-06

## Context (왜)
TestFlight MVP 이후 사용성 보강 3종:
- **다크모드**: `AppColor`는 이미 `UITraitCollection` 기반 적응형이라 시스템 다크모드는 자동 동작. 사용자가 앱에서 **수동으로 강제**(라이트/다크/시스템)할 수단이 없음.
- **메모 검색**: 메모가 쌓이면 목록에서 특정 메모를 찾기 어려움. 현재 검색 없음.
- **i18n**: 문자열이 7개 파일에 한국어로 하드코딩. 영어권 사용자 대응 불가.

다크모드·언어는 **둘 다 "앱 루트에서 override하는 영속 설정"**이라 공통 인프라(`AppSettings`)로 묶는다.

## 비목표 (이번 범위 밖)
- 서버측 전문(full-text) 검색 — 로컬 필터로 충분.
- 메모/카테고리 **데이터**의 번역 — UI 문자열만 로컬라이즈.
- 한/영 외 언어.

---

## 공통 — AppSettings
- 신규 `Memo/Services/AppSettings.swift`: `@Observable` 싱글턴 또는 `@AppStorage` 래퍼.
  - `themeMode: ThemeMode` (`.system` / `.light` / `.dark`)
  - `appLanguage: AppLanguage` (`.system` / `.ko` / `.en`)
  - `UserDefaults`에 영속.
- 앱 루트(`Memo/App/MemoApp.swift` 또는 최상위 View)에서 적용:
  - `.preferredColorScheme(settings.themeMode.colorScheme)` — `.system`이면 `nil`.
  - `.environment(\.locale, settings.appLanguage.locale)` — `.system`이면 기기 로케일.

## 1. 다크모드
- `ThemeMode.colorScheme`: system→nil, light→.light, dark→.dark.
- `SettingsView`에 "화면 테마" 섹션 — `Picker`(세그먼트): 시스템 / 라이트 / 다크. `settings.themeMode` 바인딩.
- `AppColor`(`Theme.swift`) **변경 없음** — 이미 trait 대응.
- 검증: 토글 시 전체 앱 색상 즉시 전환.

## 2. 메모 내용 검색
- 메모는 `MemoListViewModel.memos`에 전량 로드됨(오프라인 캐시 포함) → **클라이언트 필터**. 서버 쿼리 불필요.
- `MemoListViewModel`:
  - `var searchText = ""` 추가.
  - `rebuild()` 필터에 본문 매칭 AND 결합:
    - 기존 카테고리 필터 통과 + `searchText` 비었거나 `m.content.localizedCaseInsensitiveContains(searchText)`.
  - `func setSearch(_:)` 또는 `searchText` didSet에서 `rebuild()`.
- `MemoListView`: 목록에 `.searchable(text:)` 바인딩. 빈 결과 시 기존 empty 상태 문구 재사용(또는 "검색 결과 없음").
- 검증: 입력에 따라 즉시 필터, 카테고리 칩 필터와 동시 동작.

## 3. i18n (한/영)
### 문자열 카탈로그
- 신규 `Memo/Resources/Localizable.xcstrings`(String Catalog).
- 기존 한국어 문자열을 **키 겸 ko 값**으로, en 번역 추가. SwiftUI `Text("문자열")`은 카탈로그에 키가 있으면 자동 로컬라이즈.
- `project.yml`: `DEVELOPMENT_LANGUAGE: ko`(유지) + `knownRegions`/`CFBundleLocalizations`에 `en` 추가. xcodegen `options`에 필요한 설정 반영, 재생성.

### 대상 파일 (하드코딩 문자열 → 카탈로그)
- `Features/Auth/LoginView.swift`
- `Features/Compose/ComposeView.swift`
- `Features/MemoList/MemoListView.swift`
- `Features/Detail/MemoDetailView.swift`, `CategoryPickerView.swift`
- `Features/Settings/SettingsView.swift`, `CategoryManageView.swift`
- 동적 보간 문자열(예: `"메모 \(n)"`)은 `String(format:)`/`LocalizedStringKey` 보간으로 처리.

### 언어 오버라이드
- 루트 `.environment(\.locale, settings.appLanguage.locale)` — iOS16+에서 `Text` 로컬라이즈 조회가 환경 로케일을 따름 → **재시작 없이 전환**.
- `SettingsView`에 "언어" 섹션 — 시스템 / 한국어 / English.
- 주의: `.environment(\.locale)`가 안 먹는 컴포넌트(일부 시스템 UI)는 예외 가능 → 구현 중 확인, 안 되면 `AppleLanguages` 방식 폴백(재시작 필요) 검토.

---

## 작업 순서
1. AppSettings + 다크모드 (인프라 + 가장 단순)
2. 메모 검색 (독립적, 작음)
3. i18n (가장 큼, 문자열 전수 추출)

각 단계 후 시뮬레이터 빌드/동작 확인.

## Verification
- **다크모드**: 설정 토글 3종 → 앱 색상 즉시 전환, 재실행 후 유지(영속).
- **검색**: 본문 일부 입력 → 해당 메모만, 카테고리 칩과 AND, 지우면 복원.
- **i18n**: 언어 English 선택 → UI 전환(재시작 없이), 시스템 선택 시 기기 언어 따름. 누락 문자열(키 그대로 노출) 없는지 화면별 확인.
- 회귀: 기존 목록/작성/분류/설정 흐름 정상, 빌드 통과.
