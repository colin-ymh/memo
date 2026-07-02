# Supabase (DB / Edge Function)

## 스키마 (Phase 2)
`migrations/20260702000000_init.sql` — 메모·카테고리 테이블 + pgvector.

핵심:
- `memos.embedding vector(1024)` — Cohere embed-multilingual-v3(1024) 기준.
- `embedding_model / embedding_dim / embedding_version` — 모델·차원 바꿔도 옛 벡터와 혼용 방지.
- **HNSW + cosine** 인덱스(실시간 추가에 강함).
- **RLS**: 본인 데이터만. `match_memos()` 함수도 `auth.uid()`로 본인 메모만 검색.

## 적용 (사용자 계정 필요)
Supabase 프로젝트 생성은 colin 계정에서 (배포·DB 설정 → 진행 전 확인).
```bash
# Supabase CLI
supabase init            # (최초 1회)
supabase link --project-ref <ref>
supabase db push         # migrations 적용
```
또는 대시보드 SQL Editor에 마이그레이션 붙여넣기.

## 관련 메모 검색 사용 예
```sql
select * from match_memos(
  query_embedding := '[...1024개...]'::vector,  -- 새 메모의 Cohere 임베딩
  match_count := 5
);
```

## 다음 (Phase 3)
Edge Function(Deno/TS): 메모 저장 → DB Webhook → 백그라운드로
분류(Claude Haiku) + 임베딩(Cohere) + `match_memos`로 관련메모. 키는 Edge Function 환경변수에만.
