#!/bin/bash
# Stop / SubagentStop 훅: pending-report.json 이 있으면 Slack 으로 보고를 쏘고 파일을 지운다.
# 파일이 없으면 무동작. 전부 성공해야 파일 삭제(실패 시 보존하여 재시도 가능).

set -euo pipefail

DIR=".claude"
PENDING="$DIR/pending-report.json"
MAP="$DIR/report-channels.json"
TOKEN_FILE="$DIR/.slack-token"

# 1. 보고 파일 없으면 종료
[ -f "$PENDING" ] || exit 0

# 2. 토큰 로드 (env 우선, 없으면 파일)
TOKEN="${SLACK_BOT_TOKEN:-}"
if [ -z "$TOKEN" ] && [ -f "$TOKEN_FILE" ]; then
  TOKEN="$(tr -d '[:space:]' < "$TOKEN_FILE")"
fi
if [ -z "$TOKEN" ]; then
  echo "[report-to-slack] no SLACK token (env SLACK_BOT_TOKEN or $TOKEN_FILE)" >&2
  exit 0
fi

[ -f "$MAP" ] || { echo "[report-to-slack] missing $MAP" >&2; exit 0; }

# 3. python3 으로 각 항목 발사. 전부 ok 면 0, 하나라도 실패면 1(파일 보존).
set +e
TOKEN="$TOKEN" PENDING="$PENDING" MAP="$MAP" python3 <<'PY'
import json, os, sys, urllib.request

token = os.environ["TOKEN"]
pending_path = os.environ["PENDING"]
map_path = os.environ["MAP"]

with open(pending_path, encoding="utf-8") as f:
    items = json.load(f)
if isinstance(items, dict):
    items = [items]

with open(map_path, encoding="utf-8") as f:
    chan_map = json.load(f)

def post(channel_id, text):
    body = json.dumps({"channel": channel_id, "text": text}).encode("utf-8")
    req = urllib.request.Request(
        "https://slack.com/api/chat.postMessage",
        data=body,
        headers={"Authorization": f"Bearer {token}", "Content-type": "application/json"},
    )
    with urllib.request.urlopen(req) as resp:
        return json.load(resp)

emoji = {"기획": "📝", "디자인": "🎨", "개발": "🛠️"}
all_ok = True
for it in items:
    logical = it.get("channel", "work")
    cid = chan_map.get(logical, "")
    stage = it.get("stage", "기타")
    title = it.get("title", "(제목 없음)")
    summary = it.get("summary", "")
    if not cid:
        print(f"[report-to-slack] no channel id for '{logical}' in {map_path}", file=sys.stderr)
        all_ok = False
        continue
    head = emoji.get(stage, "✅")
    text = f"{head} [{stage} 완료] {title}"
    if summary:
        text += f"\n요약: {summary}"
    r = post(cid, text)
    if not r.get("ok"):
        print(f"[report-to-slack] post failed ({logical}/{cid}): {r.get('error')}", file=sys.stderr)
        all_ok = False
    else:
        print(f"[report-to-slack] sent -> {logical} ({stage}) {title}", file=sys.stderr)

sys.exit(0 if all_ok else 1)
PY
STATUS=$?
set -e

if [ "$STATUS" -eq 0 ]; then
  rm -f "$PENDING"
  echo "[report-to-slack] all sent, pending cleared" >&2
else
  echo "[report-to-slack] some sends failed, pending kept for retry" >&2
fi

exit 0
