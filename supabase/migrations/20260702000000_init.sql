-- memo 초기 스키마: 메모 + 카테고리 + 벡터 검색
-- Phase 0 확정: 임베딩 = Cohere embed-multilingual-v3 (1024차원)
-- 교차검증(Codex) 반영: 소유자 무결성 composite FK / 오프라인 동기화(soft delete
-- + 서버강제 updated_at + cursor) / match_memos 앱·Edge 분리 / HNSW 런타임 튜닝.

create extension if not exists vector with schema extensions;

-- 카테고리 -------------------------------------------------------------------
create table public.categories (
    id            uuid primary key default gen_random_uuid(),
    user_id       uuid not null references auth.users (id) on delete cascade,
    name          text not null,
    created_by_ai boolean not null default false,
    created_at    timestamptz not null default now(),
    unique (user_id, name),
    -- 아래 memos의 composite FK 대상(같은 소유자 카테고리만 연결 허용)
    unique (id, user_id)
);

-- 메모 ----------------------------------------------------------------------
create table public.memos (
    id          uuid primary key default gen_random_uuid(),
    user_id     uuid not null references auth.users (id) on delete cascade,
    content     text not null,
    category_id uuid,

    -- 임베딩 + 메타(모델/차원 바꿔도 벡터 혼용 방지)
    embedding         vector(1024),
    embedding_model   text,            -- 예: 'embed-multilingual-v3.0'
    embedding_dim     int,             -- 예: 1024
    embedding_version int not null default 1,

    -- 오프라인 우선 동기화
    created_at  timestamptz not null default now(),  -- 클라이언트 작성 시각(클라 지정 가능)
    updated_at  timestamptz not null default now(),  -- 서버 강제(trigger) → sync cursor 신뢰원
    deleted_at  timestamptz,                          -- soft delete(tombstone, 기기간 삭제 전파)

    -- 같은 소유자의 카테고리만 참조 허용. 카테고리 삭제 시 category_id만 NULL(미분류).
    constraint memos_category_owner_fkey
        foreign key (category_id, user_id)
        references public.categories (id, user_id)
        on delete set null (category_id)
);

-- 인덱스 --------------------------------------------------------------------
-- 벡터 유사도: HNSW + 코사인 (실시간 추가에 robust, IVFFlat보다 유지 편함)
create index memos_embedding_hnsw
    on public.memos using hnsw (embedding vector_cosine_ops)
    with (m = 16, ef_construction = 64);

create index memos_user_created on public.memos (user_id, created_at desc);
create index memos_category     on public.memos (category_id);
-- 증분 동기화 커서: 서버 updated_at 기준으로 delta pull
create index memos_user_updated_cursor on public.memos (user_id, updated_at, id);

-- 서버 강제 updated_at ------------------------------------------------------
create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
    new.updated_at = now();
    return new;
end;
$$;

create trigger memos_set_updated_at
    before insert or update on public.memos
    for each row execute function public.set_updated_at();

-- RLS: 본인 데이터만 -------------------------------------------------------
alter table public.categories enable row level security;
alter table public.memos      enable row level security;

create policy "own categories" on public.categories
    for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

create policy "own memos" on public.memos
    for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- 관련 메모 검색 (앱용) -----------------------------------------------------
-- authenticated 사용자가 자기 JWT로 직접 호출. auth.uid() + RLS로 본인 메모만.
create or replace function public.match_memos(
    query_embedding vector(1024),
    match_count     int  default 5,
    exclude_id      uuid default null
)
returns table (id uuid, content text, category_id uuid, similarity float)
language sql
stable
set search_path = extensions, public
set hnsw.ef_search = 100
set hnsw.iterative_scan = strict_order
as $$
    select m.id, m.content, m.category_id,
           1 - (m.embedding <=> query_embedding) as similarity
    from public.memos m
    where m.user_id = auth.uid()
      and m.embedding is not null
      and m.deleted_at is null
      and (exclude_id is null or m.id <> exclude_id)
    order by m.embedding <=> query_embedding
    limit match_count;
$$;

-- 관련 메모 검색 (Edge Function 전용) --------------------------------------
-- service_role이 백그라운드(webhook)에서 호출. JWT 없어 auth.uid()=null이므로
-- p_user_id를 명시로 받는다. service_role은 RLS 우회 → p_user_id가 유일한 격리.
-- public/authenticated에는 노출하지 않는다(권한 revoke).
create or replace function public.match_memos_for_user(
    p_user_id       uuid,
    query_embedding vector(1024),
    match_count     int  default 5,
    exclude_id      uuid default null
)
returns table (id uuid, content text, category_id uuid, similarity float)
language sql
stable
set search_path = extensions, public
set hnsw.ef_search = 100
set hnsw.iterative_scan = strict_order
as $$
    select m.id, m.content, m.category_id,
           1 - (m.embedding <=> query_embedding) as similarity
    from public.memos m
    where m.user_id = p_user_id
      and m.embedding is not null
      and m.deleted_at is null
      and (exclude_id is null or m.id <> exclude_id)
    order by m.embedding <=> query_embedding
    limit match_count;
$$;

-- 실행 권한: 앱용은 authenticated만, Edge용은 service_role만 -----------------
revoke all on function public.match_memos(vector(1024), int, uuid) from public;
grant execute on function public.match_memos(vector(1024), int, uuid) to authenticated;

revoke all on function public.match_memos_for_user(uuid, vector(1024), int, uuid) from public;
grant execute on function public.match_memos_for_user(uuid, vector(1024), int, uuid) to service_role;
