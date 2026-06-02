#!/bin/bash
# Summarize music-pipeline.sh log activity.
#
# Usage:
#   summarize.sh [--last N] [--totals] [LOGPATH]
#
# Default LOGPATH: configured PIPELINE_LOG from config/music-pipeline.env
# Default window: last 1 run (--last 1)
# --totals: skip per-run lines, print only the aggregate footer

set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd -P)"
# shellcheck disable=SC1091
. "$REPO_ROOT/lib/config.sh"

LAST=1
TOTALS_ONLY=0
LOG="$PIPELINE_LOG"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --last)    LAST=$2; shift 2;;
        --totals)  TOTALS_ONLY=1; shift;;
        -h|--help) sed -n '2,11p' "$0"; exit 0;;
        -*)        echo "Unknown flag: $1" >&2; exit 1;;
        *)         LOG=$1; shift;;
    esac
done

if [[ ! -f "$LOG" ]]; then
    echo "ERROR: log not found: $LOG" >&2
    exit 1
fi

# Extract the last LAST run-end lines and parse counters.
end_lines=$(grep -E '=== pipeline run end:' "$LOG" | tail -n "$LAST")

if [[ -z "$end_lines" ]]; then
    echo "no 'pipeline run end' lines in $LOG (window=$LAST)" >&2
    exit 1
fi

# If a single run, also show the full block for context.
if [[ "$LAST" -eq 1 && $TOTALS_ONLY -eq 0 ]]; then
    awk '
        /=== pipeline run start ===/ { buf=$0 "\n"; in_run=1; next }
        in_run { buf = buf $0 "\n" }
        /=== pipeline run end:/ && in_run { last=buf; in_run=0 }
        END { printf "%s", last }
    ' "$LOG"
    echo ""
fi

if [[ $TOTALS_ONLY -eq 0 && "$LAST" -gt 1 ]]; then
    echo "=== Per-run end markers (last $LAST) ==="
    printf '%s\n' "$end_lines"
    echo ""
fi

echo "=== Aggregate over last $LAST run(s) ==="
printf '%s\n' "$end_lines" | awk '
    BEGIN { fields = "imported dup review video_moved failed arr_skipped stuck lidarr_notified" }
    {
        for (i = 1; i <= NF; i++) {
            if (match($i, /^([a-z_]+)=([0-9]+)$/, m)) {
                tot[m[1]] += m[2]
            }
        }
        runs++
    }
    END {
        n = split(fields, order, " ")
        for (i = 1; i <= n; i++) {
            k = order[i]
            printf "  %-18s %d\n", k ":", tot[k] + 0
        }
        printf "  %-18s %d run(s)\n", "window:", runs
    }
'
