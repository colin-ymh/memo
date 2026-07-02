-- ⚠️ 이 마이그레이션은 process-memo Edge Function 배포 + Vault 시크릿 설정 후에 적용한다.
-- (지금 적용하면 Vault 시크릿이 없어 cron 실행 시 실패)
--
-- 목적: DB Webhook은 fire-and-forget(재시도 없음)이라, 분류/임베딩이 일시 실패한 메모는
--       embedding=null로 영구히 남아 recall에서 사라진다. pg_cron으로 주기적으로 훑어
--       process-memo를 재호출(보정 스윕)한다.
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
