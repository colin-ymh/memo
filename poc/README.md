# Phase 0 — 한국어 Recall PoC

제품의 핵심이자 최대 리스크(한국어 메모 의미 연결)를 **DB·앱 없이** 검증한다.
임베딩 제공자를 한국어 실측 recall로 고르는 것이 목적.

## 왜 이걸 먼저
- 관련메모 연결/Recall이 이 앱의 차별점. 임베딩 품질이 나쁘면 나머지 전부 무의미.
- 벤치마크(MTEB)는 일반 검색용 — "개인 메모 간 의미 연결"과 다름. **실측만이 답.**
- 최종 제품엔 임베딩 모델 **1개**. 여기 여러 모델은 비교용(고르면 나머지 버림).

## 준비물
- **비교 대상: OpenAI + Cohere** (2개). 환경변수로:
  - `OPENAI_API_KEY` — text-embedding-3-large
  - `COHERE_API_KEY` — embed-multilingual-v3.0
  - (선택) `VOYAGE_API_KEY` — `--providers openai,cohere,voyage`로 추가 비교
- 가상환경 + 의존성 (macOS는 PEP 668로 시스템 pip 막힘 → venv 필수):
  ```bash
  cd poc
  python3 -m venv .venv && source .venv/bin/activate
  pip install -r requirements.txt
  ```

## 데이터
`sample_memos.json` — 한국어 메모 100~200개 목표. 각 항목:
```json
{ "id": "m1", "title": "", "content": "...", "tags": [], "should_surface": ["m7","m12"] }
```
- `should_surface` = 이 메모 작성 시 "떠야 하는 과거 메모" id 목록(사람이 라벨링, ~30건).
- 현재는 브레인스토밍 예시 기반 시드 소량. 실제 팀 메모로 채워야 신뢰도↑.

## 실행
```bash
export OPENAI_API_KEY=...
export COHERE_API_KEY=...
python recall_poc.py            # 기본: openai + cohere 비교
python recall_poc.py --enrich   # 제목+본문+태그 합쳐 벡터화 A/B
```

## 측정
- Recall@5 / Recall@10 / MRR
- 정성: top-k 눈으로 — "반가운 메모 뜨나", "그럴듯한 오연결" 비율
- p95 지연, 월 예상 비용(메모 수 × 단가)
- 입력 보강 A/B: 원문만 vs `제목+본문+태그` 합쳐 벡터화

## 게이트
어느 후보도 recall 만족 못 하면 → 제품 접근(임베딩 기반 연결) 재검토.
통과한 조합(제공자·모델·차원)이 Phase 2 스키마의 `vector(N)` 차원을 정한다.
