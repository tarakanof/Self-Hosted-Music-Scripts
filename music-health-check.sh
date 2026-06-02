#!/bin/bash
# music-health-check.sh — read-only audit of beets ↔ filesystem internal consistency.
#
# Checks (all read-only, nothing is ever modified):
#   1. Duplicate album folders — same artist/album at 2+ distinct paths
#      (catches case-only dupes, year-variant dupes, split-pair multi-disc).
#   1b. Duplicate artist folders — same normalized artist name across 2+
#       distinct artist directories (catches case-only and punctuation-derived
#       variants).
#   2. Broken DB paths — beets album $path either does not exist on disk
#      (missing) or exists but has no audio files (empty-phantom, seen with
#      Mob Rules / A Broken Frame on 2026-04-23).
#   3. Orphan album folders — audio-bearing folders on disk not represented
#      in the beets DB.
#   4. Partial imports — beets track count < $albumtotal for an album with
#      a known MB track count (catches interrupted imports / missing discs).
#
# Complements (does NOT duplicate) music-lidarr-sync.sh, which covers the
# beets ↔ Lidarr axis. This script covers the beets ↔ filesystem axis.
#
# Runs weekly via /boot/config/plugins/dynamix/music-health-check.cron.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/config.sh"

# --- Configuration ---
LOG="${LOG:-$HEALTH_CHECK_LOG}"
LOCKFILE="${LOCKFILE:-$HEALTH_CHECK_LOCKFILE}"
REPORT="$HEALTH_REPORT"
REPORT_DUPS="$HEALTH_REPORT_DUPS"
REPORT_ARTIST_DUPS="$HEALTH_REPORT_ARTIST_DUPS"
REPORT_BROKEN="$HEALTH_REPORT_BROKEN"
REPORT_ORPHANS="$HEALTH_REPORT_ORPHANS"
REPORT_PARTIAL="$HEALTH_REPORT_PARTIAL"
FS_TSV="$HEALTH_FS_TSV"
BEETS_TSV="$HEALTH_BEETS_TSV"

# --- Helpers ---
log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"
}

rotate_log() {
    if [ -f "$LOG" ] && [ "$(stat -c%s "$LOG")" -gt 10485760 ]; then
        mv -f "$LOG" "$LOG.1"
    fi
}

ntfy() {
    local title="$1" body="$2" prio="${3:-default}" tags="${4:-musical_note}"
    local token=""
    [ -r "$NTFY_TOKEN_FILE" ] && token=$(head -1 "$NTFY_TOKEN_FILE")
    curl -s -m 5 \
        ${token:+-H "Authorization: Bearer $token"} \
        -H "Title: $title" \
        -H "Priority: $prio" \
        -H "Tags: $tags" \
        --data-binary "$body" \
        "$NTFY_URL" >/dev/null 2>&1 || log "ntfy send failed: $title"
}

# --- Single-instance lock ---
exec 200>"$LOCKFILE"
flock -n 200 || { log "another instance running; exit"; exit 0; }

rotate_log
log "=== health-check run start ==="

# Yield to pipeline or sync if they're running. Use flock to distinguish a
# held lock from a stale file left behind by a prior run.
for other_lock in "$PIPELINE_LOCKFILE" "$LIDARR_SYNC_LOCKFILE"; do
    [ -e "$other_lock" ] || continue
    if ! flock -n "$other_lock" -c true 2>/dev/null; then
        log "$other_lock is held by another process; skipping this run"
        exit 0
    fi
done

# --- Step 1: enumerate filesystem album folders at depth 2 ---
# Columns: artist_dir<TAB>album_dir<TAB>host_path<TAB>artist_norm<TAB>album_base_norm
# Skips Compilations/ and Soundtracks/ category roots (not artist/album-shaped).
find "$MUSIC_HOST" -mindepth 2 -maxdepth 2 -type d 2>/dev/null | \
awk -F/ '
{
    n = split($0, parts, "/")
    album = parts[n]
    artist = parts[n-1]
    path = $0
    if (artist == "Compilations" || artist == "Soundtracks") next

    # artist_norm: lowercase; drop trailing [._]+ (handles "fun." vs "fun_");
    # strip common punct; collapse whitespace.
    a = tolower(artist)
    gsub(/[_.]+$/, "", a)
    gsub(/[(),'\'':"\-]/, "", a)
    gsub(/[ \t]+/, " ", a)
    sub(/^ /, "", a); sub(/ $/, "", a)

    # album_base: strip trailing " (YYYY)" (with optional " [tag]") before norm.
    base = album
    sub(/ \([0-9]{4}\)( \[[^]]*\])?$/, "", base)
    b = tolower(base)
    gsub(/[(),'\'':"\-]/, "", b)
    gsub(/[ \t]+/, " ", b)
    sub(/^ /, "", b); sub(/ $/, "", b)

    printf "%s\t%s\t%s\t%s\t%s\n", artist, album, path, a, b
}
' > "$FS_TSV"

FS_COUNT=$(wc -l < "$FS_TSV")
log "filesystem albums (depth 2, excluding Compilations/Soundtracks): $FS_COUNT"

# --- Check 1: duplicate album folders ---
# Group by (artist_norm, album_base_norm); emit groups of size >= 2.
awk -F'\t' '
{
    key = $4 "\037" $5
    paths[key] = (paths[key] == "" ? $3 : paths[key] "\t" $3)
    count[key]++
}
END {
    for (k in count) if (count[k] > 1) printf "%d\t%s\t%s\n", count[k], k, paths[k]
}
' "$FS_TSV" | sort -r > "$REPORT_DUPS"

DUP_GROUPS=$(wc -l < "$REPORT_DUPS")
log "duplicate album groups: $DUP_GROUPS"

# --- Check 1b: duplicate artist folders ---
# Group by artist_norm, emit when 2+ distinct artist_dir values share the same
# normalized form. Catches case-only, trailing punctuation substitution, and
# diacritic variants that beets does not natively dedupe at the artist level.
awk -F'\t' '
{
    if (!(($1 SUBSEP $4) in seen)) {
        seen[$1 SUBSEP $4] = 1
        norm_artists[$4] = (norm_artists[$4] == "" ? $1 : norm_artists[$4] "\t" $1)
        norm_count[$4]++
    }
}
END {
    for (k in norm_count) if (norm_count[k] > 1) printf "%d\t%s\t%s\n", norm_count[k], k, norm_artists[k]
}
' "$FS_TSV" | sort -r > "$REPORT_ARTIST_DUPS"

ARTIST_DUP_GROUPS=$(wc -l < "$REPORT_ARTIST_DUPS")
log "duplicate artist folders: $ARTIST_DUP_GROUPS"

# --- Step 2: enumerate beets DB album paths ---
# Format: id<TAB>path<TAB>albumtotal (one row per album). Stderr suppressed.
docker exec -u "$BEETS_USER" "$BEETS_CONTAINER" beet ls -a -f '$id'$'\t''$path'$'\t''$albumtotal' 2>/dev/null > "$BEETS_TSV"
BEETS_COUNT=$(wc -l < "$BEETS_TSV")
log "beets albums: $BEETS_COUNT"

# Per-album track count (for Check 4 partial-imports) — one `beet ls` call
# that emits $album_id per track, aggregated with awk.
docker exec -u "$BEETS_USER" "$BEETS_CONTAINER" beet ls -f '$album_id' 2>/dev/null | \
    awk '{c[$1]++} END {for (k in c) printf "%s\t%s\n", k, c[k]}' \
    | sort -n > "$HEALTH_TRACK_COUNTS_TSV"

# --- Check 2: broken DB paths — missing directory OR directory exists but
#     contains no audio files (phantom path, as seen with Mob Rules and
#     A Broken Frame 2026-04-23). Status column distinguishes the two.
: > "$REPORT_BROKEN"
while IFS=$'\t' read -r id cpath _; do
    [ -z "$cpath" ] && continue
    hpath="${cpath/$MUSIC_CONT/$MUSIC_HOST}"
    if [ ! -d "$hpath" ]; then
        printf '%s\t%s\t%s\n' "$id" "missing" "$cpath" >> "$REPORT_BROKEN"
    else
        audio_count=$(find "$hpath" -maxdepth 3 -type f 2>/dev/null | grep -ciE "$MUSIC_RE")
        if [ "$audio_count" -eq 0 ]; then
            printf '%s\t%s\t%s\n' "$id" "empty" "$cpath" >> "$REPORT_BROKEN"
        fi
    fi
done < "$BEETS_TSV"

BROKEN=$(wc -l < "$REPORT_BROKEN")
log "broken DB paths: $BROKEN"

# --- Check 3: orphan album folders (audio on disk, no beets DB entry) ---
awk -F'\t' '{print $2}' "$BEETS_TSV" | sort -u > "$HEALTH_BEETS_PATHS_TSV"
awk -F'\t' -v host="$MUSIC_HOST" -v cont="$MUSIC_CONT" '
{
    p = $3
    sub(host, cont, p)
    print p
}
' "$FS_TSV" | sort -u > "$HEALTH_FS_PATHS_TSV"

: > "$REPORT_ORPHANS"
while IFS= read -r cpath; do
    hpath="${cpath/$MUSIC_CONT/$MUSIC_HOST}"
    # Only flag as orphan if the folder actually contains audio (directly or
    # in Disc-N subfolders). Artwork-only / extras-only folders are ignored.
    audio_count=$(find "$hpath" -maxdepth 3 -type f 2>/dev/null | grep -ciE "$MUSIC_RE")
    if [ "$audio_count" -gt 0 ]; then
        printf '%s\t%s\n' "$audio_count" "$cpath" >> "$REPORT_ORPHANS"
    fi
done < <(comm -23 "$HEALTH_FS_PATHS_TSV" "$HEALTH_BEETS_PATHS_TSV")

ORPHANS=$(wc -l < "$REPORT_ORPHANS")
log "orphan album folders: $ORPHANS"

# --- Check 4: partial imports (beets track count < $albumtotal, with
#     albumtotal > 0). Ignores albumtotal=0 — common for autotag-off imports
#     where the expected track count isn't known.
: > "$REPORT_PARTIAL"
# Join BEETS_TSV (id, path, albumtotal) with track-counts (album_id, count)
join -t $'\t' -1 1 -2 1 \
    <(sort -t $'\t' -k1,1 "$BEETS_TSV") \
    <(sort -t $'\t' -k1,1 "$HEALTH_TRACK_COUNTS_TSV") \
    | awk -F'\t' '
        {
            id = $1; cpath = $2; albumtotal = $3 + 0; track_count = $4 + 0
            if (albumtotal > 0 && track_count < albumtotal) {
                printf "%s\t%d/%d\t%s\n", id, track_count, albumtotal, cpath
            }
        }' > "$REPORT_PARTIAL"

PARTIAL=$(wc -l < "$REPORT_PARTIAL")
log "partial imports (count < albumtotal): $PARTIAL"

# --- Consolidated report ---
{
    echo "# music-health-check report $(date -Iseconds)"
    echo "# fs_albums=$FS_COUNT beets_albums=$BEETS_COUNT dup_groups=$DUP_GROUPS artist_dup_groups=$ARTIST_DUP_GROUPS broken=$BROKEN orphans=$ORPHANS partial=$PARTIAL"
    echo ""
    echo "## Duplicate album groups ($DUP_GROUPS) — count<TAB>artist_norm<US>album_base_norm<TAB>path1<TAB>path2..."
    cat "$REPORT_DUPS"
    echo ""
    echo "## Duplicate artist folders ($ARTIST_DUP_GROUPS) — count<TAB>artist_norm<TAB>artist_dir1<TAB>artist_dir2..."
    cat "$REPORT_ARTIST_DUPS"
    echo ""
    echo "## Broken DB paths ($BROKEN) — album_id<TAB>status(missing|empty)<TAB>beets_path"
    cat "$REPORT_BROKEN"
    echo ""
    echo "## Orphan album folders ($ORPHANS) — audio_count<TAB>container_path"
    cat "$REPORT_ORPHANS"
    echo ""
    echo "## Partial imports ($PARTIAL) — album_id<TAB>count/albumtotal<TAB>beets_path"
    cat "$REPORT_PARTIAL"
} > "$REPORT"

log "report written: $REPORT"

# --- Diff against previous run: what's NEW this week? ---
# Cached prev snapshots live alongside the current TSVs. First run just
# initialises them (no "new" delta possible).
PREV_DUPS="$HEALTH_PREV_DUPS"
PREV_ARTIST_DUPS="$HEALTH_PREV_ARTIST_DUPS"
PREV_BROKEN="$HEALTH_PREV_BROKEN"
PREV_ORPHANS="$HEALTH_PREV_ORPHANS"
PREV_PARTIAL="$HEALTH_PREV_PARTIAL"
NEW_DUPS_FILE=$(mktemp)
NEW_ARTIST_DUPS_FILE=$(mktemp)
NEW_BROKEN_FILE=$(mktemp)
NEW_ORPHANS_FILE=$(mktemp)
NEW_PARTIAL_FILE=$(mktemp)
[ -f "$PREV_DUPS" ]         || : > "$PREV_DUPS"
[ -f "$PREV_ARTIST_DUPS" ]  || : > "$PREV_ARTIST_DUPS"
[ -f "$PREV_BROKEN" ]       || : > "$PREV_BROKEN"
[ -f "$PREV_ORPHANS" ]      || : > "$PREV_ORPHANS"
[ -f "$PREV_PARTIAL" ]      || : > "$PREV_PARTIAL"
comm -23 <(sort "$REPORT_DUPS")        <(sort "$PREV_DUPS")        > "$NEW_DUPS_FILE"
comm -23 <(sort "$REPORT_ARTIST_DUPS") <(sort "$PREV_ARTIST_DUPS") > "$NEW_ARTIST_DUPS_FILE"
comm -23 <(sort "$REPORT_BROKEN")      <(sort "$PREV_BROKEN")      > "$NEW_BROKEN_FILE"
comm -23 <(sort "$REPORT_ORPHANS")     <(sort "$PREV_ORPHANS")     > "$NEW_ORPHANS_FILE"
comm -23 <(sort "$REPORT_PARTIAL")     <(sort "$PREV_PARTIAL")     > "$NEW_PARTIAL_FILE"
NEW_DUPS_COUNT=$(wc -l < "$NEW_DUPS_FILE")
NEW_ARTIST_DUPS_COUNT=$(wc -l < "$NEW_ARTIST_DUPS_FILE")
NEW_BROKEN_COUNT=$(wc -l < "$NEW_BROKEN_FILE")
NEW_ORPHANS_COUNT=$(wc -l < "$NEW_ORPHANS_FILE")
NEW_PARTIAL_COUNT=$(wc -l < "$NEW_PARTIAL_FILE")
log "new since last run: dups=$NEW_DUPS_COUNT artist_dups=$NEW_ARTIST_DUPS_COUNT broken=$NEW_BROKEN_COUNT orphans=$NEW_ORPHANS_COUNT partial=$NEW_PARTIAL_COUNT"

# --- ntfy summary ---
if [ "$DUP_GROUPS" -eq 0 ] && [ "$ARTIST_DUP_GROUPS" -eq 0 ] && [ "$BROKEN" -eq 0 ] && [ "$ORPHANS" -eq 0 ] && [ "$PARTIAL" -eq 0 ]; then
    BODY="🏥 weekly health-check: all clean ($FS_COUNT albums, $BEETS_COUNT DB entries)"
    PRIO="low"
    TAGS="white_check_mark,musical_note"
else
    BODY="🏥 weekly health-check
  📁 fs albums: $FS_COUNT
  🗄 beets albums: $BEETS_COUNT
  ♊ duplicate album groups: $DUP_GROUPS (+$NEW_DUPS_COUNT new)
  👥 duplicate artist folders: $ARTIST_DUP_GROUPS (+$NEW_ARTIST_DUPS_COUNT new)
  💔 broken DB paths: $BROKEN (+$NEW_BROKEN_COUNT new)
  👻 orphan folders: $ORPHANS (+$NEW_ORPHANS_COUNT new)
  🧩 partial imports: $PARTIAL (+$NEW_PARTIAL_COUNT new)"
    TOTAL_NEW=$((NEW_DUPS_COUNT + NEW_ARTIST_DUPS_COUNT + NEW_BROKEN_COUNT + NEW_ORPHANS_COUNT + NEW_PARTIAL_COUNT))
    if [ "$TOTAL_NEW" -gt 0 ]; then
        # Append up to 20 new items so the notification stays readable. Broken
        # paths include status (missing|empty) in field 2, path in field 3.
        NEW_LIST=$(
            awk -F'\t' '{printf "💔 [%s] %s\n", $2, $3}' "$NEW_BROKEN_FILE"
            awk -F'\t' '{printf "👻 %s\n", $2}' "$NEW_ORPHANS_FILE"
            awk -F'\t' '{printf "🧩 %s %s\n", $2, $3}' "$NEW_PARTIAL_FILE"
            awk -F'\t' '{printf "♊ %s\n", $3}' "$NEW_DUPS_FILE"
            awk -F'\t' '{printf "👥 %s\n", $3}' "$NEW_ARTIST_DUPS_FILE"
        )
        BODY="$BODY

NEW this week:
$(printf '%s' "$NEW_LIST" | head -20)"
    fi
    if [ "$BROKEN" -gt 0 ] || [ "$NEW_BROKEN_COUNT" -gt 0 ]; then
        PRIO="high"
        TAGS="warning,musical_note"
    elif [ "$TOTAL_NEW" -gt 0 ]; then
        PRIO="default"
        TAGS="information_source,musical_note"
    else
        PRIO="low"
        TAGS="information_source,musical_note"
    fi
    BODY="$BODY
  → $REPORT"
fi

ntfy "music health-check" "$BODY" "$PRIO" "$TAGS"

# Cache current TSVs for next run's diff.
cp -f "$REPORT_DUPS"        "$PREV_DUPS"
cp -f "$REPORT_ARTIST_DUPS" "$PREV_ARTIST_DUPS"
cp -f "$REPORT_BROKEN"      "$PREV_BROKEN"
cp -f "$REPORT_ORPHANS"     "$PREV_ORPHANS"
cp -f "$REPORT_PARTIAL"     "$PREV_PARTIAL"
rm -f "$NEW_DUPS_FILE" "$NEW_ARTIST_DUPS_FILE" "$NEW_BROKEN_FILE" "$NEW_ORPHANS_FILE" "$NEW_PARTIAL_FILE"

log "=== health-check run end ==="
exit 0
