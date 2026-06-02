---
name: pipeline-summarize
description: Use when checking what music-pipeline.sh's most recent hourly cron run did, or aggregating activity over the last N runs. Reads the configured pipeline log path, extracts the last "pipeline run start" block and the run-end counters (imported / dup / review / video_moved / failed / arr_skipped / stuck / lidarr_notified). Replaces ad-hoc tail+grep dances on the pipeline log.
---

# pipeline-summarize

## Overview

The hourly pipeline emits one structured log block per run, bracketed by:
```
[YYYY-MM-DD HH:MM:SS] === pipeline run start ===
... PRE-CHECK / import / review / ntfy lines ...
[YYYY-MM-DD HH:MM:SS] === pipeline run end: imported=N dup=N review=N video_moved=N failed=N arr_skipped=N stuck=N lidarr_notified=N ===
```

This skill extracts the most-recent block (or aggregates the last N) without manual `tail -n …` + `awk` from memory.

## Quick Reference

```bash
# Last run only (default)
./summarize.sh

# Last 24 runs (one day)
./summarize.sh --last 24

# Aggregate-only mode (skip the per-run lines, just totals)
./summarize.sh --last 24 --totals

# Different log
./summarize.sh /path/to/other.log
```

## Implementation

`summarize.sh` parses the run-end line directly — no heuristics, no double-counting. Each end line carries the canonical counters; the skill just sums across the requested window.

## When to Use

- After a manual `music-pipeline.sh` run, to confirm what happened.
- During a backlog drain, to track imports/dup/review/stuck deltas across consecutive runs.
- When ntfy has been quiet for a day and you want a quick "did anything actually run?" check.

**Skip when:** you need the unstructured detail (specific PRE-CHECK paths, ffmpeg errors). Read the log directly with `less` or `grep` for those.
