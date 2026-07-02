#!/usr/bin/env python3
"""Phase 1 — 메모 자동 카테고리 분류 PoC (Claude Haiku 4.5).

검증 목표:
1. 한국어/영어 메모를 기존 카테고리에 정확히 넣는가.
2. 언어가 달라도 의미 같으면 기존 카테고리 재사용(새로 안 만듦)하는가.
3. 진짜 새 주제면 새 카테고리를 제안하는가.
4. structured outputs로 JSON 스키마가 절대 안 깨지는가.

실행:
    pip install anthropic          # (poc/.venv 안에서)
    export ANTHROPIC_API_KEY=sk-ant-...
    python classify.py

키 없으면 Anthropic Console Workbench에서 아래 SYSTEM/USER를 수동으로 테스트해도 됨.
"""
from __future__ import annotations

import json
import os

import anthropic

MODEL = "claude-haiku-4-5"  # Claude 최저가, 분류에 충분

# 안정적인 규칙 = 시스템 프롬프트(캐싱 대상). 카테고리 목록은 바뀌므로 user 메시지에 둔다.
SYSTEM = """너는 개인 메모 앱의 카테고리 분류기다.

규칙:
- 사용자의 기존 카테고리 목록을 먼저 본다.
- 메모의 '의미'가 기존 카테고리 중 하나에 맞으면 그 이름을 그대로 고른다.
- **언어가 달라도 의미가 같으면 기존 카테고리를 재사용한다.** 예: 기존에 "개발"이 있고
  메모가 영어 개발 내용이면 새 "Development"를 만들지 말고 "개발"을 고른다.
- 어느 기존 카테고리에도 의미상 맞지 않을 때만 새 카테고리를 제안한다(is_new=true).
- 새 카테고리 이름은 메모와 같은 언어로, 짧고 일반적인 명사로.
- 확신이 낮으면 confidence를 낮게 준다.
"""

# 출력 스키마 — 파싱 실패 없게 강제
SCHEMA = {
    "type": "object",
    "properties": {
        "category": {"type": "string"},
        "is_new": {"type": "boolean"},
        "confidence": {"type": "number"},
        "reason": {"type": "string"},
    },
    "required": ["category", "is_new", "confidence", "reason"],
    "additionalProperties": False,
}

# 테스트: 기존 카테고리 + 여러 언어 메모(교차언어 재사용 확인 포함)
EXISTING = ["개발", "신앙", "육아", "재테크", "여행"]
TESTS = [
    "결제 모듈에서 반올림 버그. 총액이 1원씩 안 맞는다.",   # → 개발 (한국어)
    "Rounding bug in payment totals, off by one cent.",       # → 개발 (영어인데 재사용해야)
    "오늘 회개 설교 아이디어. 웨일즈 부흥에서 회개가 시작.",   # → 신앙
    "Set a stop-loss line and sell mechanically.",            # → 재테크 (영어)
    "새 앱 마케팅 문구 초안 잡기.",                            # → 새 카테고리(마케팅 등)
]


def classify(client: anthropic.Anthropic, existing: list[str], memo: str) -> dict:
    user = f"기존 카테고리: {existing}\n\n메모:\n{memo}"
    resp = client.messages.create(
        model=MODEL,
        max_tokens=300,
        system=[{"type": "text", "text": SYSTEM, "cache_control": {"type": "ephemeral"}}],
        output_config={"format": {"type": "json_schema", "schema": SCHEMA}},
        messages=[{"role": "user", "content": user}],
    )
    text = next(b.text for b in resp.content if b.type == "text")
    return json.loads(text)


def main() -> None:
    if not os.getenv("ANTHROPIC_API_KEY"):
        print("ANTHROPIC_API_KEY 없음. 발급 후 export 하거나 Workbench에서 수동 테스트.")
        return
    client = anthropic.Anthropic()
    print(f"기존 카테고리: {EXISTING}\n")
    for memo in TESTS:
        r = classify(client, EXISTING, memo)
        tag = "🆕신규" if r["is_new"] else "기존"
        print(f"[{tag}] {r['category']:12} (conf {r['confidence']:.2f})  ← {memo[:38]}")
        print(f"        이유: {r['reason']}")


if __name__ == "__main__":
    main()
