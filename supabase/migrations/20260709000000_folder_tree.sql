-- 폴더 트리 분류로 전환: 플랫 categories → 자기참조 folders(최대 3뎁스).
-- 새 모델: 사용자가 폴더 트리(Title/Description)를 직접 설계하고, AI(process-memo)는
-- 폴더를 만들지 않고 기존 트리 안에서 메모를 이동만 한다. 분류 불가 = 미분류(folder_id NULL).
-- 그린필드(실사용 데이터 없음): 기존 categories와 재사용-bias/병합 RPC를 폐기한다.
--
-- 삭제 정책: 폴더는 "빈 폴더만" 삭제(자식은 parent_id on delete restrict가 방어, 앱이 메모 0도 확인).
-- 깊이/순환: reparent(v1 포함) 때문에 depth 컬럼을 저장하지 않고 트리거로 검증만 한다.

-- 1) category 의존 객체 제거 -------------------------------------------------
drop function if exists public.merge_categories(uuid, uuid);
drop function if exists public.category_usage(uuid);

-- 2) memos: 카테고리 연결 해제 후 folder_id로 전환 --------------------------
alter table public.memos drop constraint if exists memos_category_owner_fkey;
drop index if exists public.memos_category;
alter table public.memos rename column category_id to folder_id;

-- 3) categories 폐기(그린필드) ----------------------------------------------
drop table if exists public.categories;

-- 기존 메모가 들고 있던 옛 카테고리 id는 새 folders에 없음 → 미분류로 초기화(FK 추가 전).
update public.memos set folder_id = null where folder_id is not null;

-- 4) folders: 자기참조 트리 -------------------------------------------------
create table public.folders (
    id          uuid primary key default gen_random_uuid(),
    user_id     uuid not null references auth.users (id) on delete cascade,
    parent_id   uuid references public.folders (id) on delete restrict,  -- 자식 있으면 삭제 거부
    title       text not null,
    description text,
    created_at  timestamptz not null default now(),
    -- 아래 memos의 composite FK 대상(같은 소유자 폴더만 연결 허용)
    unique (id, user_id)
);

-- 형제 폴더 이름 유일성. 일반 unique는 NULL parent_id를 서로 다르게 봐서 최상위 폴더
-- 중복이 새어나감 → coalesce sentinel로 우회(크로스버전 안전).
create unique index folders_sibling_title_uniq
    on public.folders (user_id, coalesce(parent_id, '00000000-0000-0000-0000-000000000000'::uuid), title);

create index folders_user_parent on public.folders (user_id, parent_id);

-- 5) memos ↔ folders 복합 FK. 같은 소유자 폴더만 참조. 폴더 삭제 시 folder_id만 NULL(미분류).
alter table public.memos
    add constraint memos_folder_owner_fkey
    foreign key (folder_id, user_id)
    references public.folders (id, user_id)
    on delete set null (folder_id);

create index memos_folder on public.memos (folder_id);

-- 6) 트리 무결성 트리거: 깊이 ≤3, 순환 금지, parent 소유자 일치 ----------------
-- reparent(UPDATE OF parent_id) 시 new 서브트리 전체의 최대 깊이를 재검증한다.
create or replace function public.enforce_folder_tree()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
    v_node_depth    int;   -- new 노드의 루트까지 절대 깊이(자기 포함, 최상위=1)
    v_subtree_depth int;   -- new 서브트리의 최대 상대 깊이(new=1)
begin
    if new.parent_id is not null then
        -- 6a) parent가 같은 소유자인지
        if not exists (
            select 1 from public.folders
            where id = new.parent_id and user_id = new.user_id
        ) then
            raise exception '부모 폴더가 없거나 소유자가 다릅니다';
        end if;

        -- 6b) 순환: new가 자기 자신을 부모로 두거나, parent의 조상 체인에 new.id가 있으면 거부
        if new.id = new.parent_id or exists (
            with recursive anc as (
                select p.id, p.parent_id
                from public.folders p
                where p.id = new.parent_id
                union all
                select p.id, p.parent_id
                from public.folders p
                join anc on p.id = anc.parent_id
            )
            select 1 from anc where id = new.id
        ) then
            raise exception '폴더 순환 참조';
        end if;
    end if;

    -- 6c) new 노드의 절대 깊이(부모 없으면 1). BEFORE라 new는 아직 테이블에 없어 앵커로 사용.
    with recursive up as (
        select new.parent_id as pid, 1 as lvl
        union all
        select p.parent_id, up.lvl + 1
        from public.folders p
        join up on p.id = up.pid
        where up.pid is not null
    )
    select max(lvl) into v_node_depth from up;

    -- 6d) new 서브트리의 최대 상대 깊이. INSERT면 자식이 없어 1. reparent면 자손 포함.
    with recursive down as (
        select new.id as id, 1 as rel
        union all
        select c.id, down.rel + 1
        from public.folders c
        join down on c.parent_id = down.id
        where c.id <> new.id  -- 순환 안전장치
    )
    select max(rel) into v_subtree_depth from down;

    if coalesce(v_node_depth, 1) + coalesce(v_subtree_depth, 1) - 1 > 3 then
        raise exception '폴더 깊이는 최대 3단계입니다';
    end if;

    return new;
end;
$$;

create trigger folders_enforce_tree
    before insert or update of parent_id on public.folders
    for each row execute function public.enforce_folder_tree();

-- 7) RLS: 본인 폴더만 -------------------------------------------------------
alter table public.folders enable row level security;

create policy "own folders" on public.folders
    for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- 8) 벡터 검색 RPC 재생성 — 반환 컬럼 category_id → folder_id ------------------
-- OUT 컬럼명 변경은 create or replace로 불가 → drop 후 재생성.
drop function if exists public.match_memos(vector(1024), int, uuid);
drop function if exists public.match_memos_for_user(uuid, vector(1024), int, uuid);
drop function if exists public.related_memos(uuid, int, float);

-- 관련 메모 검색 (앱용)
create function public.match_memos(
    query_embedding vector(1024),
    match_count     int  default 5,
    exclude_id      uuid default null
)
returns table (id uuid, content text, folder_id uuid, similarity float)
language sql
stable
set search_path = extensions, public
set hnsw.ef_search = 100
set hnsw.iterative_scan = strict_order
as $$
    select m.id, m.content, m.folder_id,
           1 - (m.embedding <=> query_embedding) as similarity
    from public.memos m
    where m.user_id = auth.uid()
      and m.embedding is not null
      and m.deleted_at is null
      and (exclude_id is null or m.id <> exclude_id)
    order by m.embedding <=> query_embedding
    limit match_count;
$$;

-- 관련 메모 검색 (Edge Function 전용, service_role)
create function public.match_memos_for_user(
    p_user_id       uuid,
    query_embedding vector(1024),
    match_count     int  default 5,
    exclude_id      uuid default null
)
returns table (id uuid, content text, folder_id uuid, similarity float)
language sql
stable
set search_path = extensions, public
set hnsw.ef_search = 100
set hnsw.iterative_scan = strict_order
as $$
    select m.id, m.content, m.folder_id,
           1 - (m.embedding <=> query_embedding) as similarity
    from public.memos m
    where m.user_id = p_user_id
      and m.embedding is not null
      and m.deleted_at is null
      and (exclude_id is null or m.id <> exclude_id)
    order by m.embedding <=> query_embedding
    limit match_count;
$$;

-- 관련 메모 RPC (앱용, memo_id로 서버에서 임베딩 조회)
create function public.related_memos(
    p_memo_id     uuid,
    match_count   int   default 5,
    min_similarity float default 0.65
)
returns table (id uuid, content text, folder_id uuid, similarity float)
language plpgsql
stable
set search_path = extensions, public
as $$
declare
    v_uid uuid := auth.uid();
    v_emb vector(1024);
begin
    select me.embedding into v_emb
    from public.memos me
    where me.id = p_memo_id and me.user_id = v_uid and me.deleted_at is null;

    if v_emb is null then
        return;
    end if;

    return query
        select m.id, m.content, m.folder_id,
               1 - (m.embedding <=> v_emb) as similarity
        from public.memos m
        where m.user_id = v_uid
          and m.embedding is not null
          and m.deleted_at is null
          and m.id <> p_memo_id
          and (1 - (m.embedding <=> v_emb)) >= min_similarity
        order by m.embedding <=> v_emb
        limit match_count;
end;
$$;

-- 실행 권한 재부여(init과 동일 정책) ----------------------------------------
revoke all on function public.match_memos(vector(1024), int, uuid) from public;
grant execute on function public.match_memos(vector(1024), int, uuid) to authenticated;

revoke all on function public.match_memos_for_user(uuid, vector(1024), int, uuid) from public;
grant execute on function public.match_memos_for_user(uuid, vector(1024), int, uuid) to service_role;

revoke all on function public.related_memos(uuid, int, float) from public, anon;
grant execute on function public.related_memos(uuid, int, float) to authenticated;
