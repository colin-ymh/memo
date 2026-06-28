# memo — AI 메모 앱

## 프로젝트 개요
AI 기반 메모 앱. 사용자가 메모를 작성하면 AI가 자동으로 카테고리 분류 후 저장.

## 팀
- **Colin** — 개발 총괄 (Claude와 함께)
- **기획자** — 기획 위주, 추후 개발 참여 가능성 있음

## 기술 스택 결정사항

| 항목 | 선택 | 이유 |
|------|------|------|
| 앱 | Swift 네이티브 (iOS) | WidgetKit Swift 전용, CoreData + CloudKit 조합 자연스러움 |
| 백엔드 | Supabase | PostgreSQL 기반, 비용 예측 가능, 무료 티어 실용적 |
| 인증 | Google OAuth | 초기 단일 소셜 로그인 |
| AI 분류 | Claude Haiku API | 단순 분류 작업에 최저가 |
| 저장 | 오프라인 로컬 우선 → 클라우드 동기화 | |

## MVP 범위 (2주 목표)
- [ ] 메모 작성
- [ ] AI 자동 카테고리 분류
- [ ] 사용자 정의 카테고리
- [ ] 클라우드 동기화 (Supabase)
- [ ] Google OAuth 로그인
- [ ] App Store 출시

## MVP 제외 (v1.1)
- 홈 화면 위젯 (WidgetKit — iOS 위젯 인터랙션 제약으로 별도 검토 필요)
- Android 지원

## 타겟 플랫폼
- iOS 우선 출시
- Android는 추후 별도 프로젝트 (Flutter 또는 RN) 검토

## 수익 모델
- 구독 또는 인앱결제

## 작업 규칙
- 언어: 한국어로 소통
- 코드 변경 후 변경 파일, 이유, 리스크, 커밋 메시지만 보고
- `.env`, 시크릿, 배포 설정 변경 전 반드시 확인

## Slack 보고 규칙 (작업 단위 완료 시 자동 보고)
한 작업 단계가 **완료**됐을 때만 Slack 보고를 남긴다. Stop 훅
(`.claude/hooks/report-to-slack.sh`)이 이를 감지해 자동 발사한다.

### 동작
- 단계를 완료하면 `.claude/pending-report.json`에 보고 1건(또는 배열)을 기록한다.
  ```json
  [{ "channel": "work", "stage": "개발", "title": "작업명", "summary": "한두 줄 요약" }]
  ```
  - `channel`: `work` | `plan` | `chat` (논리 키, `.claude/report-channels.json`에서 실제 ID로 매핑)
  - `stage`: `기획` | `디자인` | `개발` | `기타`
  - `title`: 작업명 / `summary`: 한두 줄 요약 (그 외 항목은 넣지 않는다)
- 일반 대화·질문·중간 진행 턴에는 **기록하지 않는다**. 단계 완료 시점에만 쓴다.
- 훅이 발사 후 파일을 삭제하므로, 보고할 때마다 새로 쓴다.

### 라우팅
- 개별 단계(기획/디자인/개발) 완료 → `work` (memo-업무보고)
- 기능 전체 완료·큰 플랜 단위 → `plan` (memo-플랜)
- `chat` (memo-잡담) → 자동 보고 대상 아님. 명시 요청 시에만.
