#!/bin/bash
# Regression suite for .claude/hooks/bash-destructive-guard.sh.
# Each fixture line: EXPECT|LABEL|COMMAND. EXPECT is one of ALLOW/deny/ask.
# Run: bash .claude/hooks/tests/run-tests.sh

set -u

GUARD="$(dirname "$0")/../bash-destructive-guard.sh"
FIX="$(dirname "$0")/fixtures.txt"

[[ -x "$GUARD" ]] || { echo "guard not executable: $GUARD" >&2; exit 1; }
[[ -f "$FIX" ]]   || { echo "fixtures missing: $FIX" >&2; exit 1; }

fails=0
total=0
while IFS='|' read -r expect label cmd; do
    [[ -z "${expect:-}" || "$expect" =~ ^# ]] && continue
    total=$((total+1))
    out=$(jq -nc --arg c "$cmd" '{tool_name:"Bash",tool_input:{command:$c}}' | "$GUARD")
    if [[ -z "$out" ]]; then
        actual="ALLOW"
    else
        actual=$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null || echo PARSE_ERR)
    fi
    if [[ "$actual" == "$expect" ]]; then
        printf 'PASS [%s]\n' "$label"
    else
        printf 'FAIL [%s] expected=%s got=%s\n  cmd: %s\n' "$label" "$expect" "$actual" "$cmd"
        [[ -n "$out" ]] && printf '  out: %s\n' "$out"
        fails=$((fails+1))
    fi
done < "$FIX"

echo "---"
echo "$((total-fails))/$total passed; $fails failures"
exit "$fails"
