#!/bin/bash
# PostToolUse hook for Edit|Write. Runs `bash -n` on shell scripts after they
# are edited so a syntax error doesn't slip into the hourly cron unnoticed.
#
# Reads tool-call JSON on stdin. Emits decision-block JSON only on failure.

set -u

file=$(jq -r '.tool_response.filePath // .tool_input.file_path // empty')

[[ -z "$file" ]] && exit 0
[[ ! -f "$file" ]] && exit 0

case "$file" in
    *.sh|*.bash) ;;
    *) exit 0 ;;
esac

if ! err=$(bash -n "$file" 2>&1); then
    jq -n --arg f "$file" --arg err "$err" '{
        decision: "block",
        reason: ("bash -n syntax check failed for " + $f + ":\n" + $err)
    }'
    exit 0
fi

exit 0
