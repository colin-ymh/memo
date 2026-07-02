-- memo 초기 스키마: 메모 + 카테고리 + 벡터 검색
-- Phase 0 확정: 임베딩 = Cohere embed-multilingual-v3 (1024차원)

create extension if not exists vector;

-- 카테고리 -------------------------------------------------------------------
create table public.categories (
    id            uuid primary key default gen_random_uuid(),
    user_id       uuid not null references auth.users (id) on delete cascade,
    name          text not null,
    created_by_ai boolean not null default false,
    created_at    timestamptz not null default now(),
    unique (user_id, name)
);

-- 메모 ----------------------------------------------------------------------
create table public.memos (
    id          uuid primary key default gen_random_uuid(),
    user_id     uuid not null references auth.users (id) on delete cascade,
    content     text not null,
    category_id uuid references public.categories (id) on delete set null,

    -- 임베딩 + 메타(모델/차원 바꿔도 벡터 혼용 방지)
    embedding         vector(1024),
    embedding_model   text,            -- 예: 'embed-multilingual-v3.0'
    embedding_dim     int,             -- 예: 1024
    embedding_version int not null default 1,

    created_at  timestamptz not null default now(),
    updated_at  timestamptz not null default now()
);

-- 인덱스 --------------------------------------------------------------------
-- 벡터 유사도: HNSW + 코사인 (실시간 추가에 robust, IVFFlat보다 유지 편함)
create index memos_embedding_hnsw
    on public.memos using hnsw (embedding vector_cosine_ops)
    with (m = 16, ef_construction = 64);

create index memos_user_created on public.memos (user_id, created_at desc);
create index memos_category     on public.memos (category_id);

-- RLS: 본인 데이터만 -------------------------------------------------------
alter table public.categories enable row level security;
alter table public.memos      enable row level security;

create policy "own categories" on public.categories
    for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

create policy "own memos" on public.memos
    for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

-- 관련 메모 검색 함수 -------------------------------------------------------
-- security invoker(기본)라 auth.uid() 적용 → RLS로 본인 메모만.
-- 새 메모 벡터를 넣어 의미상 가까운 과거 메모 top-k 반환(자기 자신 제외).
create or replace function public.match_memos(
    query_embedding vector(1024),
    match_count     int  default 5,
    exclude_id      uuid default null
)
returns table (id uuid, content text, category_id uuid, similarity float)
language sql
stable
as $$
    select m.id, m.content, m.category_id,
           1 - (m.embedding <=> query_embedding) as similarity
    from public.memos m
    where m.user_id = auth.uid()
      and m.embedding is not null
      and (exclude_id is null or m.id <> exclude_id)
    order by m.embedding <=> query_embedding
    limit match_count;
$$;
