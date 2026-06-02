#!/bin/bash
# One-time (or occasional manual) lyrics backfill. The lyrics plugin's
# `auto: yes` handles new imports via the pipeline, so this script is NOT
# scheduled. Run when you need to populate pre-existing tracks, or as a
# manual retry sweep if you notice gaps in a player.
#
# Per-album loop so partial progress is preserved in DB and file tags
# incrementally — safe to interrupt and rerun. Without -f, tracks already
# having lyrics are skipped, so reruns are cheap.
#
# Run:     nohup ./music-lyrics-sweep.sh </dev/null >/dev/null 2>&1 &
# Monitor: tail -f "$LYRICS_SWEEP_LOG"
# Status:  ps -fp $(cat /tmp/music-lyrics-sweep.lock)

set -u
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/config.sh"

LOG="${LOG:-$LYRICS_SWEEP_LOG}"
LOCK="$LYRICS_SWEEP_LOCKFILE"

if [ -e "$LOCK" ] && kill -0 "$(cat "$LOCK")" 2>/dev/null; then
    echo "already running (PID $(cat "$LOCK"))" >&2
    exit 1
fi
echo $$ > "$LOCK"
trap 'rm -f "$LOCK"' EXIT

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG"; }

log "=== sweep start ==="
total_albums=$(docker exec -u "$BEETS_USER" "$BEETS_CONTAINER" beet ls -a -f '$id' </dev/null | wc -l)
log "library has $total_albums albums; tracks missing lyrics: $(docker exec -u "$BEETS_USER" "$BEETS_CONTAINER" beet ls -f '$id' '^lyrics::.' </dev/null | wc -l)"

i=0
docker exec -u "$BEETS_USER" "$BEETS_CONTAINER" beet ls -a -f '$id' </dev/null | while read aid; do
    i=$((i+1))
    # Skip if all tracks already have lyrics — saves a network call per album.
    missing=$(docker exec -u "$BEETS_USER" "$BEETS_CONTAINER" beet ls -f '$id' "album_id:$aid" '^lyrics::.' </dev/null | wc -l)
    if [ "$missing" -eq 0 ]; then
        continue
    fi
    artist_album=$(docker exec -u "$BEETS_USER" "$BEETS_CONTAINER" beet ls -a -f '$albumartist - $album' "id:$aid" </dev/null)
    log "[$i/$total_albums] album_id=$aid ($artist_album) — $missing missing"
    timeout 600 docker exec -u "$BEETS_USER" "$BEETS_CONTAINER" beet lyrics "album_id:$aid" </dev/null >> "$LOG" 2>&1
    timeout 60 docker exec -u "$BEETS_USER" "$BEETS_CONTAINER" beet write "album_id:$aid" </dev/null >> "$LOG" 2>&1
done

log "=== sweep done ==="
