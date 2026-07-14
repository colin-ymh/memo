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
