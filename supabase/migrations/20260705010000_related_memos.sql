-- 앱(authenticated)용 관련 메모 RPC.
-- match_memos는 query_embedding(1024벡터)을 인자로 받는데, 앱은 임베딩을 로컬에 안 갖고 있다.
-- 그래서 memo_id만 받아 서버에서 임베딩을 조회한 뒤 top-k 유사 메모를 반환한다.
-- 유사도 임계값(min_similarity)으로 약한 연결(노이즈) 컷. 기본 0.65(실데이터로 튜닝).
-- SECURITY INVOKER(기본) + auth.uid() → 본인 메모만(RLS와 정합).
create or replace function public.related_memos(
    p_memo_id     uuid,
    match_count   int   default 5,
    min_similarity float default 0.65
)
returns table (id uuid, content text, category_id uuid, similarity float)
language plpgsql
stable
set search_path = extensions, public
as $$
declare
    v_uid uuid := auth.uid();
    v_emb vector(1024);
begin
    -- 기준 메모의 임베딩(본인 것만). 로컬 변수라 아래 쿼리에서 상수처럼 쓰여 HNSW 인덱스 사용 가능.
    select embedding into v_emb
    from public.memos
    where id = p_memo_id and user_id = v_uid and deleted_at is null;

    if v_emb is null then
        return;  -- 아직 분류/임베딩 전이면 관련 메모 없음
    end if;

    return query
        select m.id, m.content, m.category_id,
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

revoke all on function public.related_memos(uuid, int, float) from public, anon;
grant execute on function public.related_memos(uuid, int, float) to authenticated;
