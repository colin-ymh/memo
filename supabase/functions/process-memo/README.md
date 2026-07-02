# process-memo

메모 INSERT → 백그라운드 분류(Claude Haiku) + 임베딩(Cohere) → `memos` 갱신.

## 배포 전 필수 (🔴 하드스톱)
이전 채팅에 노출된 **Anthropic·Cohere 키는 폐기·재발급**하고, 새 키로만 아래 시크릿 설정.
키를 repo·config.toml·커밋된 .env 어디에도 넣지 않는다.

## 시크릿 (Edge Function secrets)
`SUPABASE_URL`, `SUPABASE_SERVICE_ROLE_KEY`는 Supabase가 자동 주입. 추가로 설정할 것:

```
supabase secrets set ANTHROPIC_API_KEY=sk-ant-...
supabase secrets set COHERE_API_KEY=...
supabase secrets set WEBHOOK_SECRET=<임의 난수>   # openssl rand -hex 32
```

## 배포
```
supabase functions deploy process-memo    # config.toml의 verify_jwt=false 적용됨
```

## DB Webhook 배선 (대시보드 → Database → Webhooks)
- Table: `public.memos`
- Events: **Insert 만** (Update/Delete 체크 해제 — 자기 UPDATE 재트리거 방지)
- Type: HTTP Request → `POST https://<ref>.supabase.co/functions/v1/process-memo`
- HTTP Headers: `x-webhook-secret: <WEBHOOK_SECRET 값>`

## stuck 메모 보정 (클라 트리거 방식 채택)
webhook은 fire-and-forget이라 일시 실패한 메모는 `embedding=null`로 남는다.
보정은 **pg_cron 상시 폴링 대신 클라 트리거**로 한다(결정):
- 앱 포그라운드 진입/동기화 시 본인의 `embedding is null`(+n분 경과) 메모를 감지
- 전용 **authenticated** 엔드포인트(JWT 인증 RPC/Edge)가 재처리 → 유저가 recall 보기 전 healing
- 구현은 Phase 4(iOS). 앱은 service_role이 없으므로 webhook-secret 경로가 아닌 인증 경로로.

`migrations/20260702020000_reconcile_stuck_memos.sql`(pg_cron)은 **미적용 fallback**으로만 남김
(대량 백필/운영 보정 필요 시 수동 적용).

## 동작 요약
1. `x-webhook-secret` 검증 → 2. `embedding` 있으면 skip(멱등)
3. 유저 기존 카테고리 조회 → 4. Haiku 분류(tool 강제 JSON) + Cohere 임베딩(병렬, 각 재시도)
5. 카테고리 upsert(race-safe) → 6. `memos` 갱신(category_id·embedding·메타)

관련 메모 recall은 읽기 시점에 앱이 `match_memos`(authenticated)로 직접 호출.
Edge Function은 `match_memos_for_user`(service_role)를 쓸 수 있으나 현재 경로에선 미사용.
