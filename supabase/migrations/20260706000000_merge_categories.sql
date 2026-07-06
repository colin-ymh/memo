-- 카테고리 수동 병합 RPC — source의 모든 메모를 target으로 옮기고 source 삭제.
-- 누적된 유사 카테고리를 사용자가 직접 정리(예: "여행계획" → "여행")하는 용도.
-- SECURITY INVOKER(기본): update/delete가 호출자 권한으로 실행되어 memos/categories의
-- RLS "own" 정책이 소유권을 강제 → 본인 카테고리만 병합 가능(타 유저 것 건드릴 수 없음).
-- 한 함수 = 한 트랜잭션이라 재지정+삭제가 원자적.
create or replace function public.merge_categories(
    p_source uuid,
    p_target uuid
)
returns void
language plpgsql
set search_path = public
as $$
declare
    v_uid uuid := auth.uid();
begin
    if p_source = p_target then
        raise exception 'source와 target이 같음';
    end if;
    -- target이 본인 카테고리인지 확인(존재/소유). source는 아래 delete의 소유 조건으로 검증.
    if not exists (select 1 from public.categories where id = p_target and user_id = v_uid) then
        raise exception 'target 카테고리 없음 또는 권한 없음';
    end if;

    update public.memos
       set category_id = p_target
     where category_id = p_source and user_id = v_uid;

    delete from public.categories
     where id = p_source and user_id = v_uid;
end;
$$;

revoke all on function public.merge_categories(uuid, uuid) from public, anon;
grant execute on function public.merge_categories(uuid, uuid) to authenticated;


-- 분류기(process-memo, service_role) 전용 — 유저의 카테고리별 메모 수 집계.
-- LLM에 "이미 N개 쌓인 카테고리"를 힌트로 줘 재사용을 편향(무한 파편화 억제).
-- 전체 메모 행을 끌어와 클라에서 세지 않도록 DB에서 GROUP BY(=그룹 수만큼만).
-- service_role은 RLS 우회하므로 p_user_id를 명시로 받는다(엣지 함수가 유저 검증 후 호출).
create or replace function public.category_usage(p_user_id uuid)
returns table (name text, n bigint)
language sql
stable
set search_path = public
as $$
    select c.name, count(m.id) as n
    from public.categories c
    left join public.memos m
        on m.category_id = c.id and m.deleted_at is null
    where c.user_id = p_user_id
    group by c.name;
$$;

revoke all on function public.category_usage(uuid) from public, anon, authenticated;
grant execute on function public.category_usage(uuid) to service_role;
