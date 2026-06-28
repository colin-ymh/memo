#!/bin/bash

input="$(cat)"

command=$(printf '%s' "$input" | python3 -c "
import sys, json
data = json.load(sys.stdin)
print(data.get('tool_input', {}).get('command', ''))
")

# 너무 큰 출력이 자주 나는 패턴 차단
if [[ "$command" =~ ^cat[[:space:]].*\.log$ ]] || \
   [[ "$command" =~ ^cat[[:space:]].*/package-lock\.json$ ]] || \
   [[ "$command" =~ ^find[[:space:]].*\.[[:space:]]*$ ]] || \
   [[ "$command" =~ ^ls[[:space:]]-R ]] || \
   [[ "$command" =~ ^grep[[:space:]].*-R[[:space:]].*node_modules ]] || \
   [[ "$command" =~ ^rg[[:space:]].*node_modules ]]; then
  echo '{
    "hookSpecificOutput": {
      "hookEventName": "PreToolUse",
      "permissionDecision": "deny",
      "permissionDecisionReason": "출력이 너무 큰 명령은 차단합니다. tail, rg, git diff --stat, grep -n, head 같은 더 좁은 명령을 사용하세요."
    }
  }'
  exit 0
fi

exit 0
