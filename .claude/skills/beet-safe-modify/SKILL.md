---
name: beet-safe-modify
description: Use when about to run beet modify, remove, move, update, or write with the -a (album-context) flag in this music repo. Pre-flights the query with `beet ls -a` first, prints the matched albums, and aborts when the match count differs from expected. Prevents album-context query surprises before destructive beets operations.
---

# beet-safe-modify

## Overview

In beets, `id:N` and `album_id:N` behave differently depending on command context. With `-a` album-context commands, prefer album `id:N`; `album_id:N` is track-side and can match unexpectedly. This skill enforces the dry-run discipline: list first, count, abort on surprise, then act.

## When to Use

Any `beet -a ...` invocation that mutates state:
- `beet modify -a -y <query> field=value`
- `beet remove -a -f <query>`
- `beet move -a <query>`
- `beet update -a <query>`
- `beet write -a <query>`

Also worth using for the rare scoped `beet update <query>` (no `-a`) — it still deletes records whose files moved.

**Skip when:** read-only ops (`beet ls`, `beet info`, `beet stats`), or item-level ops with explicit `album_id:N` AND no `-a` flag (those are tracks, fine to be plural).

## Quick Reference

```bash
# safest default — matches exactly 1 album
./safe-beet.sh --query 'id:1477' -- modify -a -y id:1477 albumartist='milet' original_year=2021

# explicit multi-album expectation
./safe-beet.sh --query 'albumartist:Bring Me the Horizon' --expect 12 -- write 'albumartist:Bring Me the Horizon'

# bypass when you've already confirmed the count manually
./safe-beet.sh --query 'comp:1' --force-multi -- modify -a -y comp:1 albumtype=compilation
```

## Implementation

The wrapper is `safe-beet.sh` in this skill directory. Invoke it from this
repository so it can load `lib/config.sh`:

```bash
./.claude/skills/beet-safe-modify/safe-beet.sh \
  --query 'id:N' -- modify -a -y id:N field=value
```

Behavior:
1. Runs `docker exec -u "$BEETS_USER" "$BEETS_CONTAINER" beet ls -a -f '$id|$albumartist|$album|$path' <query>` and prints the matches.
2. Counts non-empty lines, compares against `--expect` (default 1).
3. Aborts (exit 2) on mismatch unless `--force-multi`.
4. On match, runs `docker exec -u "$BEETS_USER" "$BEETS_CONTAINER" beet <args after -->`.

## Common Mistakes

| Mistake | What happens | Fix |
|---|---|---|
| Broad query for what you think is one album | Matches multiple albums | Use a specific album `id:N` and keep `--expect 1` |
| Skip the wrapper "for a quick fix" | A surprising query can mutate multiple albums | The fix-album-tags skill already calls beet directly when it knows the count is 1; for ad-hoc work, use this wrapper |
| `--force-multi` without manually verifying | Defeats the point | Only use after running `beet ls -a <query>` yourself and counting |

## Red Flags — STOP

- About to run `beet remove -a -f album_id:N` → **album_id is the substring trap.** Use `id:N` with `-a`.
- About to run `beet update` without a query → **purges every drifted record.** Always scope; consider `beet write` instead.
- "I'll just chain the commands and check after" → no, list first.
