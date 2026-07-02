-- ⚠️ 미적용 옵션(fallback). 기본 채택 안 함.
-- 결정: stuck 메모 보정은 pg_cron 상시 폴링 대신 "클라 트리거"로 한다.
--   오프라인 우선 앱이라 앱 포그라운드 진입/동기화 시점에 본인 stuck 메모를 재처리하면
--   유저가 recall을 보기 전에 healing된다(복귀 안 한 유저는 recall도 안 보므로 무해).
--   → 클라 트리거 구현은 Phase 4(iOS)에서. 자세한 건 process-memo/README 참고.
--
-- 이 파일은 대량 백필/운영 보정 등 필요 시에만 수동 적용하는 fallback으로 남긴다.
-- (적용하려면 process-memo 배포 + Vault 시크릿 2개 선행)
--
-- 목적(적용 시): DB Webhook은 fire-and-forget(재시도 없음)이라 일시 실패한 메모가
--       embedding=null로 남는다. pg_cron으로 주기적으로 훑어 process-memo를 재호출한다.
--
-- 사전 준비(Supabase 대시보드 또는 SQL):
--   1) Edge Function 배포: process-memo
--   2) Vault에 시크릿 2개 저장
--      select vault.create_secret('https://<ref>.supabase.co/functions/v1/process-memo', 'process_memo_url');
--      select vault.create_secret('<WEBHOOK_SECRET 값>', 'process_memo_webhook_secret');

create extension if not exists pg_cron;
create extension if not exists pg_net;

select cron.schedule(
  'reconcile-stuck-memos',
  '*/5 * * * *',
  $$
    select net.http_post(
      url := (select decrypted_secret from vault.decrypted_secrets where name = 'process_memo_url'),
      headers := jsonb_build_object(
        'content-type', 'application/json',
        'x-webhook-secret', (select decrypted_secret from vault.decrypted_secrets where name = 'process_memo_webhook_secret')
      ),
      body := jsonb_build_object('type', 'INSERT', 'record', to_jsonb(m.*))
    )
    from public.memos m
    where m.embedding is null
      and m.created_at < now() - interval '3 minutes'   -- 방금 들어온 건 정상 webhook에 맡김
      and m.created_at > now() - interval '7 days'       -- 너무 오래된 건 포기(무한 재시도 방지)
    limit 50
  $$
);
