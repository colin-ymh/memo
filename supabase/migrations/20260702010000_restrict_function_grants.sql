-- 함수 실행 권한 하드닝
-- 이유: Supabase는 public 스키마 함수 생성 시 default privileges로 anon/authenticated/
-- service_role에 EXECUTE를 개별 grant한다. 앞선 init 마이그레이션의 `revoke all from
-- public`은 PUBLIC 권한만 회수하므로 개별 role grant가 남아 있었다.
-- match_memos_for_user는 service_role 전용(RLS 우회 + p_user_id 격리)이어야 하므로
-- anon/authenticated의 EXECUTE를 명시적으로 회수한다.
-- (RLS가 invoker 함수에 적용되어 실 유출은 없었으나, 역할 경계를 명확히 한다.)

revoke execute on function public.match_memos_for_user(uuid, vector(1024), int, uuid)
    from public, anon, authenticated;
grant execute on function public.match_memos_for_user(uuid, vector(1024), int, uuid)
    to service_role;

-- 앱용 match_memos는 authenticated 전용. anon(비로그인) 회수.
revoke execute on function public.match_memos(vector(1024), int, uuid)
    from public, anon;
grant execute on function public.match_memos(vector(1024), int, uuid)
    to authenticated;
