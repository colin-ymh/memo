-- 메모 핀 고정. 기존 "own memos" RLS 정책이 그대로 커버(같은 테이블 컬럼).
-- 정렬은 앱에서 is_pinned desc, created_at desc.
alter table public.memos
    add column if not exists is_pinned boolean not null default false;
