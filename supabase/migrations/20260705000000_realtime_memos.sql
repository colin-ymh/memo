-- Realtime: 앱이 memos 변경(분류 완료 등)을 실시간 구독하려면 publication에 추가해야 한다.
-- (분류/임베딩은 백그라운드 async → 앱은 Realtime으로 "분류 중→칩" 반영)
-- RLS는 Realtime에도 적용되어 본인 행 변경만 수신한다.
alter publication supabase_realtime add table public.memos;
