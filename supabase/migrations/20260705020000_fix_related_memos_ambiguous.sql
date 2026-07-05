-- 버그픽스: related_memos에서 "column reference 'id' is ambiguous".
-- RETURNS TABLE의 out 파라미터 id가 plpgsql 변수가 되어, SELECT INTO의 무한정 id와 충돌.
-- 기준 메모 조회의 컬럼을 테이블 별칭(me.)으로 한정한다.
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
    select me.embedding into v_emb
    from public.memos me
    where me.id = p_memo_id and me.user_id = v_uid and me.deleted_at is null;

    if v_emb is null then
        return;
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
