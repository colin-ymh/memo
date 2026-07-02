#!/usr/bin/env python3
"""Phase 0 — 한국어 Recall PoC.

임베딩 제공자별로 한국어 메모를 벡터화하고, leave-one-out 최근접 이웃으로
Recall@k / MRR 를 재서 어느 제공자·모델·차원이 한국어 의미 연결을 잘하는지 비교한다.

DB 없음. in-memory 코사인. 키 있는 제공자만 돈다.

사용:
    export OPENAI_API_KEY=...
    python poc/recall_poc.py
    python poc/recall_poc.py --providers openai,voyage,cohere --enrich
"""
from __future__ import annotations

import argparse
import json
import os
import time
from pathlib import Path

import numpy as np

HERE = Path(__file__).parent
DATA = HERE / "sample_memos.json"


# --- 임베딩 입력 텍스트 구성 -------------------------------------------------
def memo_text(m: dict, enrich: bool, use_tags: bool = False) -> str:
    if not enrich:
        return m["content"]
    parts = []
    if m.get("title"):
        parts.append(f"제목: {m['title']}")
    parts.append(f"본문: {m['content']}")
    # 태그는 기본 제외 — 목업 태그가 테마명이라 정답 힌트로 새면 점수 부풀림.
    # 실제 앱의 AI 카테고리 효과를 보려면 --tags 로 켜서 별도 확인.
    if use_tags and m.get("tags"):
        parts.append(f"태그: {', '.join(m['tags'])}")
    return "\n".join(parts)


# --- 제공자별 임베딩 함수 (키 있는 것만 로드) --------------------------------
def _chunks(xs: list, n: int):
    for i in range(0, len(xs), n):
        yield xs[i : i + n]


def embed_openai(texts: list[str], model: str, dim: int | None) -> np.ndarray:
    from openai import OpenAI

    client = OpenAI()
    out = []
    for batch in _chunks(texts, 96):
        kwargs = {"model": model, "input": batch}
        if dim:
            kwargs["dimensions"] = dim
        resp = client.embeddings.create(**kwargs)
        out.extend(d.embedding for d in resp.data)
    return np.array(out, dtype=np.float32)


def embed_voyage(texts: list[str], model: str, dim: int | None) -> np.ndarray:
    import voyageai

    client = voyageai.Client()
    out = []
    for batch in _chunks(texts, 96):
        r = client.embed(batch, model=model, input_type="document")
        out.extend(r.embeddings)
    return np.array(out, dtype=np.float32)


def embed_cohere(texts: list[str], model: str, dim: int | None) -> np.ndarray:
    import cohere

    client = cohere.Client()
    out = []
    for batch in _chunks(texts, 96):
        r = client.embed(texts=batch, model=model, input_type="search_document")
        out.extend(r.embeddings)
    return np.array(out, dtype=np.float32)


# (제공자, 라벨, 함수, 모델, 차원, 필요한 env 키)
CONFIGS = {
    "openai": [
        ("openai/3-large@1024", embed_openai, "text-embedding-3-large", 1024, "OPENAI_API_KEY"),
        ("openai/3-large@3072", embed_openai, "text-embedding-3-large", 3072, "OPENAI_API_KEY"),
    ],
    "voyage": [
        ("voyage-3", embed_voyage, "voyage-3", None, "VOYAGE_API_KEY"),
    ],
    "cohere": [
        ("cohere-multilingual-v3", embed_cohere, "embed-multilingual-v3.0", None, "COHERE_API_KEY"),
    ],
}


# --- 평가 -------------------------------------------------------------------
def cosine_rank(vecs: np.ndarray, i: int) -> list[int]:
    """메모 i 기준 나머지 메모를 코사인 유사도 내림차순 정렬한 인덱스."""
    v = vecs / (np.linalg.norm(vecs, axis=1, keepdims=True) + 1e-9)
    sims = v @ v[i]
    sims[i] = -np.inf  # 자기 자신 제외
    return list(np.argsort(-sims))


def evaluate(memos: list[dict], vecs: np.ndarray) -> dict:
    id_to_idx = {m["id"]: k for k, m in enumerate(memos)}
    r5 = r10 = mrr = 0.0
    n = 0
    for i, m in enumerate(memos):
        gold = [id_to_idx[g] for g in m.get("should_surface", []) if g in id_to_idx]
        if not gold:
            continue
        n += 1
        ranked = cosine_rank(vecs, i)
        gold_set = set(gold)
        top5 = set(ranked[:5])
        top10 = set(ranked[:10])
        r5 += len(gold_set & top5) / len(gold_set)
        r10 += len(gold_set & top10) / len(gold_set)
        # MRR: 첫 정답의 역순위
        for rank, idx in enumerate(ranked, 1):
            if idx in gold_set:
                mrr += 1.0 / rank
                break
    if n == 0:
        return {"labeled": 0}
    return {"labeled": n, "recall@5": r5 / n, "recall@10": r10 / n, "mrr": mrr / n}


def lang_of(m: dict) -> str:
    for lg in ("en", "ja", "es"):
        if lg in m.get("tags", []):
            return lg
    return "ko"


def evaluate_split(memos: list[dict], vecs: np.ndarray) -> dict:
    """정답 링크를 같은언어/교차언어로 갈라 micro-average recall@k."""
    id_to_idx = {m["id"]: k for k, m in enumerate(memos)}
    hit = {"same5": 0, "same10": 0, "cross5": 0, "cross10": 0}
    tot = {"same": 0, "cross": 0}
    for i, m in enumerate(memos):
        gold = [id_to_idx[g] for g in m.get("should_surface", []) if g in id_to_idx]
        if not gold:
            continue
        ranked = cosine_rank(vecs, i)
        top5, top10 = set(ranked[:5]), set(ranked[:10])
        for g in gold:
            kind = "same" if lang_of(memos[g]) == lang_of(m) else "cross"
            tot[kind] += 1
            if g in top5:
                hit[kind + "5"] += 1
            if g in top10:
                hit[kind + "10"] += 1
    def r(a, b):
        return hit[a] / tot[b] if tot[b] else float("nan")
    return {
        "same_n": tot["same"], "same@5": r("same5", "same"), "same@10": r("same10", "same"),
        "cross_n": tot["cross"], "cross@5": r("cross5", "cross"), "cross@10": r("cross10", "cross"),
    }


def show_crosslingual(memos: list[dict], vecs: np.ndarray, label: str) -> None:
    """외국어 태그(en/ja/es) 달린 라벨 메모의 top-5를 출력해 교차언어 연결을 눈으로."""
    langs = {"en", "ja", "es"}
    print(f"\n----- {label}: 교차언어 top-5 (✓=정답) -----")
    for i, m in enumerate(memos):
        if not m.get("should_surface") or not (set(m.get("tags", [])) & langs):
            continue
        gold = set(m["should_surface"])
        ranked = cosine_rank(vecs, i)[:5]
        print(f"\n[{m['id']}] {m['content'][:50]}")
        for idx in ranked:
            mark = "✓" if memos[idx]["id"] in gold else " "
            print(f"   {mark} {memos[idx]['id']}: {memos[idx]['content'][:44]}")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--providers", default="openai,cohere", help="쉼표구분: openai,cohere,voyage")
    ap.add_argument("--enrich", action="store_true", help="제목+본문 합쳐 벡터화")
    ap.add_argument("--tags", action="store_true", help="enrich에 태그도 포함(편향 확인용)")
    ap.add_argument("--show", action="store_true", help="교차언어(영/일/스페인어) 메모의 top-5를 눈으로")
    ap.add_argument("--split", action="store_true", help="같은언어 vs 교차언어 recall 분리 측정")
    args = ap.parse_args()

    memos = json.loads(DATA.read_text(encoding="utf-8"))
    labeled = sum(1 for m in memos if m.get("should_surface"))
    print(f"메모 {len(memos)}개, 라벨링된 메모 {labeled}개, enrich={args.enrich}\n")
    if labeled < 10:
        print("⚠️  라벨(should_surface)이 너무 적음. sample_memos.json 채워야 신뢰도↑\n")

    texts = [memo_text(m, args.enrich, args.tags) for m in memos]
    rows = []
    for prov in args.providers.split(","):
        prov = prov.strip()
        for label, fn, model, dim, env in CONFIGS.get(prov, []):
            if not os.getenv(env):
                print(f"skip {label} ({env} 없음)")
                continue
            t0 = time.time()
            try:
                vecs = fn(texts, model, dim)
            except Exception as e:
                print(f"FAIL {label}: {e}")
                continue
            dt = time.time() - t0
            metrics = evaluate(memos, vecs)
            rows.append((label, metrics, dt))
            if args.split:
                s = evaluate_split(memos, vecs)
                print(f"[split] {label:26} 같은언어(n={s['same_n']}) @5={s['same@5']:.3f} @10={s['same@10']:.3f}"
                      f"  |  교차언어(n={s['cross_n']}) @5={s['cross@5']:.3f} @10={s['cross@10']:.3f}")
            if args.show:
                show_crosslingual(memos, vecs, label)

    if not rows:
        print("\n돌린 제공자 없음 — 키 확인. 최소 OPENAI_API_KEY 필요.")
        return

    print("\n=== 결과 (recall 높을수록 좋음) ===")
    print(f"{'모델':28} {'R@5':>7} {'R@10':>7} {'MRR':>7} {'초':>6}")
    for label, m, dt in sorted(rows, key=lambda r: -r[1].get("recall@10", 0)):
        print(f"{label:28} {m.get('recall@5',0):7.3f} {m.get('recall@10',0):7.3f} "
              f"{m.get('mrr',0):7.3f} {dt:6.1f}")
    print("\n※ 숫자만 믿지 말고 top-k를 눈으로 확인해 '반가운 메모 뜨나' 정성 평가할 것.")


if __name__ == "__main__":
    main()
