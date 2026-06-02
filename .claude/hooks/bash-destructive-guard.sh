#!/bin/bash
# PreToolUse hook for Bash. Blocks the two patterns AGENTS.md documents
# as having caused real data loss in this repo, and asks for explicit
# confirmation on a third (`beet update`) that is dangerous even when scoped.
#
# Reads tool-call JSON on stdin, writes a hookSpecificOutput JSON on stdout.
#
# Implementation:
#   1. Split the command on top-level shell separators (;, &, |, newline).
#      Splitting is approximate — doesn't perfectly track quoted text or
#      heredoc bodies — but combined with the per-segment first-word skip
#      below it handles the common false-positive classes (git commit
#      heredocs, cat/grep over logs containing the patterns as text).
#   2. For each segment: skip when the leading executable cannot itself
#      invoke beet/rsync (git, echo, cat, grep, etc.). Otherwise apply
#      the three pattern checks.
#   3. First match wins — emit the JSON decision and exit.
#
# Tests live at .claude/hooks/tests/. Run them after any regex change.

set -u

cmd=$(jq -r '.tool_input.command // ""')

emit_decision() {
    local decision=$1 reason=$2
    jq -n --arg d "$decision" --arg r "$reason" '{
        hookSpecificOutput: {
            hookEventName: "PreToolUse",
            permissionDecision: $d,
            permissionDecisionReason: $r
        }
    }'
    exit 0
}

# Split on top-level shell separators. Each element of "$cmd" between
# `;`, `&`, `|`, or a newline becomes its own segment.
while IFS= read -r seg || [[ -n "$seg" ]]; do
    # Trim leading whitespace
    seg="${seg#"${seg%%[![:space:]]*}"}"
    [[ -z "$seg" ]] && continue

    # First executable word of this segment.
    first=$(printf '%s' "$seg" | sed -nE 's/^([^[:space:];|&<>()]+).*/\1/p')

    # Commands that never invoke beet/rsync directly. Skipping them per
    # segment means a chained form like `git commit -m '...' && rsync …`
    # still gets the rsync segment checked.
    case "$first" in
        git|gh|echo|printf|cat|less|more|head|tail|grep|egrep|fgrep|rg|awk|sed|jq|wc|sort|uniq|comm|diff|ls|find|stat|file|date|true|false|test|pwd)
            continue
            ;;
    esac

    # --- Pattern 1: `beet -a ... album_id:N` substring trap -------------------
    # Wiped 37 albums on 2026-04-25 and 204 on 2026-04-17. In album-context
    # `album_id:148` matches every album whose id contains '148' (148, 1481-1488,
    # 2148...). The exact-album form is `id:N` with `-a`.
    if [[ "$seg" =~ ^((sudo[[:space:]]+)?docker[[:space:]]+exec[[:space:]]+([^|;&]+[[:space:]]+)?beets[[:space:]]+)?beet[[:space:]]+(remove|modify|move|update|write) ]] \
       && [[ "$seg" =~ [[:space:]]-a[a-z]*([[:space:]]|$) ]] \
       && [[ "$seg" =~ album_id:[0-9]+ ]]; then
        emit_decision "deny" \
"Blocked: 'beet -a ... album_id:N' is the substring-match trap documented in AGENTS.md. \
album_id:148 matches every album whose id contains '148' (148, 1481-1488, 2148). \
This pattern wiped 37 albums on 2026-04-25 and 204 on 2026-04-17. \
Use 'id:N' with -a — that matches exactly one album. \
For pre-flight discipline, run via .claude/skills/beet-safe-modify/safe-beet.sh."
    fi

    # --- Pattern 2: rsync --remove-source-files /mnt/user/ -------------------
    # The shfs FUSE layer can redirect writes to PUA-suffixed folders, then
    # delete sources after the bytes go elsewhere. Destroyed 13 P.O.D. albums
    # on 2026-04-17. `rsync` must be at segment-start (or after sudo).
    if [[ "$seg" =~ ^(sudo[[:space:]]+)?rsync([[:space:]]|$) ]] \
       && [[ "$seg" =~ --remove-source-files ]] \
       && [[ "$seg" =~ /mnt/user/ ]]; then
        emit_decision "deny" \
"Blocked: 'rsync --remove-source-files' against /mnt/user/. \
The shfs FUSE layer can resolve the destination to a PUA-suffixed folder \
while still deleting the source after rsync reports success — bytes go nowhere recoverable. \
This destroyed 13 P.O.D. albums on 2026-04-17. \
Use 'mv' instead, or rsync without --remove-source-files plus a reviewed delete."
    fi

    # --- Pattern 3: `beet update` — ask, don't block --------------------------
    # Even when scoped, `beet update` deletes records for files missing at
    # recorded \$path within the matched set. Often the safer choice is
    # `beet write <query>` (DB → files, no deletion).
    if [[ "$seg" =~ ^((sudo[[:space:]]+)?docker[[:space:]]+exec[[:space:]]+([^|;&]+[[:space:]]+)?beets[[:space:]]+)?beet[[:space:]]+update ]] \
       && ! [[ "$seg" =~ (-h|--help) ]]; then
        emit_decision "ask" \
"Confirm: 'beet update' is destructive even when scoped — it deletes DB records \
for any file missing at its recorded \$path within the query's matched set \
(2026-04-22 incident: 3 tracks dropped from album 73). \
Prefer 'beet write <query>' (DB → file tags, no deletion) for tag pushes, \
or 'beet move <query>' (relocate to template path) for path drift. \
If you've already verified the matched files are present at their DB \$path, allow."
    fi
done < <(printf '%s' "$cmd" | tr ';|&\n' '\n')

# Default: silent allow.
exit 0
