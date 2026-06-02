#!/bin/bash
# Pre-flight wrapper for destructive beet -a operations.
#
# Usage:
#   safe-beet.sh --query <Q> [--expect N] [--force-multi] -- <full beet args>
#
# Examples:
#   safe-beet.sh --query 'id:1477' -- modify -a -y id:1477 albumartist='milet' original_year=2021
#   safe-beet.sh --query 'id:148'  --expect 1   -- remove -a -f id:148
#   safe-beet.sh --query 'comp:1'  --force-multi -- modify -a -y comp:1 albumtype=compilation
#
# Exits:
#   0  success (preflight passed, beet command ran)
#   1  usage error
#   2  preflight aborted (count != expected)

set -u

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$SCRIPT_DIR/../../.." && pwd -P)"
# shellcheck disable=SC1091
. "$REPO_ROOT/lib/config.sh"

QUERY=""
EXPECT=1
FORCE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --query)        QUERY=$2; shift 2;;
        --expect)       EXPECT=$2; shift 2;;
        --force-multi)  FORCE=1; shift;;
        --)             shift; break;;
        -h|--help)
            sed -n '2,18p' "$0"
            exit 0
            ;;
        *) echo "Unknown flag: $1" >&2; exit 1;;
    esac
done

if [[ -z "$QUERY" ]]; then
    echo "ERROR: --query is required" >&2
    echo "Usage: safe-beet.sh --query <Q> [--expect N] [--force-multi] -- <beet args>" >&2
    exit 1
fi

if [[ $# -eq 0 ]]; then
    echo "ERROR: missing beet args after --" >&2
    exit 1
fi

echo "Pre-flight: docker exec -u $BEETS_USER $BEETS_CONTAINER beet ls -a -f '\$id|\$albumartist|\$album|\$path' '$QUERY'"
matches=$(docker exec -u "$BEETS_USER" "$BEETS_CONTAINER" beet ls -a -f '$id|$albumartist|$album|$path' "$QUERY")

if [[ -z "$matches" ]]; then
    count=0
else
    count=$(printf '%s\n' "$matches" | wc -l)
fi

printf '%s\n' "$matches"
echo "--- match count: $count (expected: $EXPECT) ---"

if [[ $FORCE -eq 0 && $count -ne $EXPECT ]]; then
    echo "" >&2
    echo "ABORT: matched $count, expected $EXPECT." >&2
    echo "If intentional, re-run with --expect $count or --force-multi." >&2
    exit 2
fi

echo ""
echo "Proceeding: docker exec -u $BEETS_USER $BEETS_CONTAINER beet $*"
docker exec -u "$BEETS_USER" "$BEETS_CONTAINER" beet "$@"
