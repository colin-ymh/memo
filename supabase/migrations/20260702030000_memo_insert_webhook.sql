-- memos INSERT → process-memo Edge Function 자동 호출(트리거 + pg_net).
-- 대시보드 Database Webhook 대신 트리거로 배선한 이유: 헤더 시크릿을 트리거 정의에
-- 박지 않고 발사 시점에 Vault에서 읽어 온다(repo·catalog에 시크릿 미노출).
--
-- 사전 준비(적용 후, 1회): Vault에 시크릿 2개.
--   select vault.create_secret('<WEBHOOK_SECRET 값>', 'process_memo_webhook_secret');
--   -- URL은 이 마이그레이션이 넣어둠(민감정보 아님).
--
-- Vault 이름은 reconcile 스윕(20260702020000)과 동일하게 공유한다.

create extension if not exists pg_net;

create or replace function public.tg_process_memo()
returns trigger
language plpgsql
security definer                 -- vault.decrypted_secrets 읽기 위해
set search_path = ''
as $$
declare
  v_url    text;
  v_secret text;
begin
  select decrypted_secret into v_url
    from vault.decrypted_secrets where name = 'process_memo_url';
  select decrypted_secret into v_secret
    from vault.decrypted_secrets where name = 'process_memo_webhook_secret';

  -- 시크릿 미설정 시 조용히 건너뜀(메모 저장 자체는 막지 않는다). reconcile가 나중에 보정.
  if v_url is null or v_secret is null then
    raise warning 'process_memo webhook skipped: vault secret 미설정';
    return new;
  end if;

  perform net.http_post(
    url     := v_url,
    headers := jsonb_build_object(
                 'Content-Type', 'application/json',
                 'x-webhook-secret', v_secret
               ),
    body    := jsonb_build_object('type', 'INSERT', 'record', to_jsonb(new))
  );
  return new;
end;
$$;

-- INSERT 전용(자기 UPDATE 재트리거 방지). 행 단위.
create trigger memos_process_after_insert
  after insert on public.memos
  for each row execute function public.tg_process_memo();
