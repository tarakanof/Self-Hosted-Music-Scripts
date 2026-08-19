#!/bin/bash
# music-pipeline.sh — Automated torrent post-processing for Unraid.
# Flow: Transmission finished → classify → Music via Beets (FLAC→ALAC + tag + art),
# Video auto-moved to Media/{Movies,Series,Anime}, unmatched music → review quarantine.
#
# Runs hourly from /etc/cron.d/root via /boot/config/plugins/dynamix/music-pipeline.cron

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/config.sh"

# --- Configuration ---
LOG="${LOG:-$PIPELINE_LOG}"
LOCKFILE="${LOCKFILE:-$PIPELINE_LOCKFILE}"
DRY_RUN="${DRY_RUN:-0}"    # DRY_RUN=1 logs actions without performing them

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

lidarr_notify_artist() {
    # Best-effort: look up artistId by exact name, fire RefreshArtist.
    # Never fails the pipeline — logs and returns on any error.
    local artist="$1"
    [ -z "$artist" ] && return 0
    [ ! -r "$LIDARR_KEY_FILE" ] && { log "lidarr: key file unreadable, skip notify for $artist"; return 0; }
    local key
    key=$(head -1 "$LIDARR_KEY_FILE")
    [ -z "$key" ] && { log "lidarr: empty key, skip notify for $artist"; return 0; }

    local artists_json
    artists_json=$(curl -s -m 10 -H "X-Api-Key: $key" "$LIDARR_URL/api/v1/artist" 2>/dev/null)
    if [ -z "$artists_json" ]; then
        log "lidarr: artist list fetch failed for '$artist'"
        return 0
    fi

    local aid
    aid=$(printf '%s' "$artists_json" | jq -r --arg name "$artist" '.[] | select(.artistName == $name) | .id' 2>/dev/null | head -1)
    if [ -z "$aid" ]; then
        log "lidarr: artist '$artist' not found in Lidarr catalog"
        return 0
    fi

    local resp
    resp=$(curl -s -m 10 -X POST \
        -H "X-Api-Key: $key" \
        -H "Content-Type: application/json" \
        -d "{\"name\":\"RefreshArtist\",\"artistId\":$aid}" \
        "$LIDARR_URL/api/v1/command" 2>/dev/null)
    if printf '%s' "$resp" | jq -e '.id' >/dev/null 2>&1; then
        log "lidarr: RefreshArtist queued for '$artist' (artistId=$aid)"
    else
        log "lidarr: RefreshArtist failed for '$artist' (artistId=$aid): $resp"
    fi
}

tr_field() {
    # $1 = full -i output, $2 = field name (e.g. "Name")
    printf '%s\n' "$1" | sed -n "s/^  $2: //p" | head -1
}

ensure_beets_running() {
    if ! docker ps --format '{{.Names}}' | grep -q "^${BEETS_CONTAINER}$"; then
        log "Starting $BEETS_CONTAINER container..."
        docker start "$BEETS_CONTAINER" >/dev/null 2>&1 || {
            log "FATAL: failed to start $BEETS_CONTAINER container"
            ntfy "Pipeline error" "Failed to start $BEETS_CONTAINER container" high "x,musical_note"
            exit 1
        }
        sleep 4
    fi
}

# Count audio files under a directory, recursively. Mirrors how MUSIC_COUNT is
# computed for the download side so the two are directly comparable.
album_audio_count() {
    find "$1" -type f 2>/dev/null | grep -ciE "$MUSIC_RE"
}

get_tr_password() {
    if [ -n "$TRANSMISSION_RPC_PASSWORD_FILE" ] && [ -r "$TRANSMISSION_RPC_PASSWORD_FILE" ]; then
        head -1 "$TRANSMISSION_RPC_PASSWORD_FILE"
        return
    fi
    if [ -n "$TRANSMISSION_RPC_PASSWORD" ]; then
        printf '%s\n' "$TRANSMISSION_RPC_PASSWORD"
        return
    fi
    docker inspect "$TRANSMISSION_CONTAINER" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
        | sed -n "s/^${TRANSMISSION_PASSWORD_ENV}=//p" | head -1
}

# --- Single-instance lock ---
exec 200>"$LOCKFILE"
flock -n 200 || exit 0

rotate_log
log "=== pipeline run start ==="

ensure_beets_running

TR_PASS=$(get_tr_password)
if [ -z "$TR_PASS" ]; then
    log "FATAL: could not retrieve Transmission password"
    ntfy "Pipeline error" "Could not get Transmission password" high "x,musical_note"
    exit 1
fi

TR=(docker exec "$TRANSMISSION_CONTAINER" transmission-remote "$TRANSMISSION_RPC_HOST" -n "${TRANSMISSION_RPC_USER}:${TR_PASS}")

# --- Collect finished torrent IDs (avoid subshell pitfall) ---
mapfile -t ALL_IDS < <("${TR[@]}" -l 2>/dev/null | awk 'NR>1 && $1 ~ /^[0-9]+$/ {print $1}')

log "Found ${#ALL_IDS[@]} torrents in Transmission"

IMPORTED=0
REVIEWED=0
FAILED=0
VIDEO_MOVED=0
SKIPPED_ARR=0
DUPLICATES=0
STUCK=()
declare -A LIDARR_NOTIFY_ARTISTS=()

for ID in "${ALL_IDS[@]}"; do
    INFO=$("${TR[@]}" -t "$ID" -i 2>/dev/null)
    [ -z "$INFO" ] && continue

    NAME=$(tr_field "$INFO" "Name")
    STATE=$(tr_field "$INFO" "State")
    LOCATION=$(tr_field "$INFO" "Location")
    RATIO=$(tr_field "$INFO" "Ratio")
    PERCENT=$(tr_field "$INFO" "Percent Done")

    # Track stuck torrents (for end-of-run report)
    # Truncate to an integer: Transmission reports percentDone as a float
    # (e.g. 99.2), and the `-eq 100` / `= "0"` tests below require integers.
    pct_num=$(printf '%s' "$PERCENT" | tr -d '%' | awk '{printf "%d", $1+0}')
    if [ "$pct_num" = "0" ] && [ "$STATE" != "Downloading" ] && [ "$STATE" != "Queued" ]; then
        STUCK+=("$ID:$NAME")
        continue
    fi

    # Process Finished, or Idle at 100% complete.
    # "Finished" = hit ratio/idle limit, stopped seeding.
    # "Idle" + 100% = downloaded fully but seed-paused; pipeline removes the
    # torrent before processing anyway, so it's safe to treat as ready.
    # 0%-Idle is filtered above as STUCK.
    if [ "$STATE" != "Finished" ]; then
        if ! { [ "$STATE" = "Idle" ] && [ "$pct_num" -eq 100 ]; }; then
            continue
        fi
    fi

    # Skip anything managed by Sonarr/Radarr, plus the books drop-zone.
    # books/ holds audiobooks (single-file .m4a) — they parse as "music" by
    # extension and trigger the wrap-then-fail loop in beets. Not a music
    # pipeline target; user processes them separately.
    if should_skip_download_location "$LOCATION"; then
        log "skip arr-managed: $NAME ($LOCATION)"
        SKIPPED_ARR=$((SKIPPED_ARR + 1))
        continue
    fi

    # Map container location to host path
    HOST_LOC=$(container_downloads_to_host_path "$LOCATION")
    SRC="$HOST_LOC/$NAME"

    if [ ! -e "$SRC" ]; then
        # Some torrent creators sanitize filesystem-unsafe chars (", <, >, :,
        # |, ?, *, \) to _ in file paths while leaving the Name header intact.
        # Try a sanitized fallback before giving up.
        NAME_ALT=$(printf '%s' "$NAME" | tr '"<>:|?*\\' '________')
        SRC_ALT="$HOST_LOC/$NAME_ALT"
        if [ "$NAME_ALT" != "$NAME" ] && [ -e "$SRC_ALT" ]; then
            log "source name sanitized on disk: '$NAME' → '$NAME_ALT'"
            SRC="$SRC_ALT"
            NAME="$NAME_ALT"
        else
            log "WARN: source not found: $SRC"
            continue
        fi
    fi

    log "processing: $NAME (id=$ID ratio=$RATIO)"

    if [ "$DRY_RUN" = "1" ]; then
        log "  DRY_RUN: would remove from Transmission + process SRC=$SRC"
        continue
    fi

    # Remove from Transmission (keep data on disk)
    "${TR[@]}" -t "$ID" -r >/dev/null 2>&1 || {
        log "WARN: could not remove torrent $ID from Transmission"
    }

    # Handle ZIP files: extract, then retarget SRC to extracted dir
    if [ -f "$SRC" ] && [[ "$NAME" =~ \.zip$ ]]; then
        EXTRACT_DIR="${SRC%.zip}"
        log "extracting zip: $NAME"
        if unzip -q -o "$SRC" -d "$EXTRACT_DIR" 2>>"$LOG"; then
            rm -f "$SRC"
            SRC="$EXTRACT_DIR"
            NAME="${NAME%.zip}"
        else
            log "ERROR: unzip failed for $NAME"
            FAILED=$((FAILED + 1))
            ntfy "Pipeline error" "unzip failed: $NAME" high "x,musical_note"
            continue
        fi
    fi

    # --- Classify: music vs video vs unknown ---
    if [ -f "$SRC" ]; then
        lower_name=$(printf '%s' "$NAME" | tr '[:upper:]' '[:lower:]')
        if [[ "$lower_name" =~ $MUSIC_RE ]]; then
            MUSIC_COUNT=1; VIDEO_COUNT=0
        elif [[ "$lower_name" =~ $VIDEO_RE ]]; then
            MUSIC_COUNT=0; VIDEO_COUNT=1
        else
            MUSIC_COUNT=0; VIDEO_COUNT=0
        fi
    else
        MUSIC_COUNT=$(find "$SRC" -type f 2>/dev/null | grep -iE "$MUSIC_RE" | wc -l)
        VIDEO_COUNT=$(find "$SRC" -type f 2>/dev/null | grep -iE "$VIDEO_RE" | wc -l)
    fi

    # === MUSIC FLOW ===
    if [ "$MUSIC_COUNT" -gt 0 ]; then
        log "detected music ($MUSIC_COUNT audio files): $NAME"

        # Single-file songs: wrap in a temp subfolder so beets can import
        WRAPPED=0
        if [ -f "$SRC" ]; then
            WRAPPER="$HOST_COMPLETE/.wrap-$ID"
            mkdir -p "$WRAPPER"
            mv "$SRC" "$WRAPPER/"
            SRC="$WRAPPER"
            NAME=".wrap-$ID"
            WRAPPED=1
        fi

        # Pre-check: does this album already exist in /music? (case-insensitive)
        # Beets duplicate detection uses MatchQuery (case-sensitive), so it misses
        # cases like "Master Of Reality" vs "Master of Reality". Catch it here.
        FIRST_AUDIO=$(find "$SRC" -type f 2>/dev/null | grep -iE "$MUSIC_RE" | head -1)
        if [ -n "$FIRST_AUDIO" ]; then
            CONTAINER_AUDIO=$(host_to_container_downloads_path "$FIRST_AUDIO")
            TAGS=$(docker exec -u "$BEETS_USER" "$BEETS_CONTAINER" ffprobe -v error -show_entries format_tags=albumartist,artist,album -of default=nw=1 "$CONTAINER_AUDIO" 2>/dev/null || true)
            # ffprobe tag names vary: FLAC/Vorbis may use ARTIST/ALBUMARTIST/ALBUM ARTIST/album_artist,
            # MP4 uses album_artist. Match case-insensitively and accept underscore/space separators.
            PC_ALBUMARTIST=$(printf '%s\n' "$TAGS" | sed -nE 's/^TAG:album[_ ]?artist=//Ip' | head -1)
            PC_ARTIST=$(printf '%s\n' "$TAGS" | sed -nE 's/^TAG:artist=//Ip' | head -1)
            PC_ALBUM=$(printf '%s\n' "$TAGS" | sed -nE 's/^TAG:album=//Ip' | head -1)
            [ -z "$PC_ALBUMARTIST" ] && PC_ALBUMARTIST="$PC_ARTIST"

            if [ -n "$PC_ALBUMARTIST" ] && [ -n "$PC_ALBUM" ]; then
                # Case-insensitive match on both artist dir and album dir, using
                # find -iname so bracket/bang/star metachars in tags don't break
                # glob parsing. Match exact album name OR "Album (year)" suffix —
                # NOT "Album <anything>" because that wrongly matched
                # "Unleashed" → "Unleashed Beyond" (different album, different
                # year) on 2026-04-24 and rm -rf'd the Skillet/Unleashed source.
                dup_match=""
                while IFS= read -r ad; do
                    [ -d "$ad" ] || continue
                    while IFS= read -r m; do
                        [ -d "$m" ] || continue
                        if [ "$(find "$m" -maxdepth 2 -type f 2>/dev/null | grep -ciE "$MUSIC_RE")" -gt 0 ]; then
                            dup_match="$m"
                            break 2
                        fi
                    done < <(find "$ad" -mindepth 1 -maxdepth 1 -type d \
                        \( -iname "$PC_ALBUM" -o -iname "$PC_ALBUM (*)" -o -iname "$PC_ALBUM \[*\]" \) 2>/dev/null)
                done < <(find "$MUSIC_HOST" -mindepth 1 -maxdepth 1 -type d \
                    -iname "$PC_ALBUMARTIST" 2>/dev/null)
                if [ -n "$dup_match" ]; then
                    # A name match alone does not mean the download is redundant:
                    # it may be a more complete edition of an album we only
                    # partly own (e.g. a 14-track release vs our 13-track rip).
                    # Deleting those is why such gaps could never be filled, so
                    # route them to review for a human decision instead.
                    LIB_COUNT=$(album_audio_count "$dup_match")
                    if [ "$MUSIC_COUNT" -gt "$LIB_COUNT" ]; then
                        log "PRE-CHECK upgrade candidate: $NAME ($MUSIC_COUNT tracks) vs $dup_match ($LIB_COUNT tracks)"
                        mkdir -p "$REVIEW_DIR"
                        if mv -f "$SRC" "$REVIEW_DIR/" 2>/dev/null; then
                            REVIEWED=$((REVIEWED + 1))
                            ntfy "Upgrade candidate" \
                                "${NAME} has $MUSIC_COUNT tracks vs $LIB_COUNT in ${dup_match##*/} — moved to review" \
                                default "mag,musical_note"
                        else
                            log "ERROR: could not move $SRC to review"
                        fi
                        continue
                    fi
                    log "PRE-CHECK duplicate: $NAME matches $dup_match"
                    rm -rf "$SRC"
                    DUPLICATES=$((DUPLICATES + 1))
                    ntfy "Duplicate skipped" "${NAME} (library has: ${dup_match##*/})" low "recycle,musical_note"
                    continue
                fi
            fi
        fi

        # Pre-convert FLAC → ALAC (all-or-nothing)
        CONV_OUT=$(docker exec -i -u "$BEETS_USER" "$BEETS_CONTAINER" bash -s "$NAME" "$CONTAINER_DOWNLOADS_ROOT" <<'CONVERT_SH'
set -uo pipefail
NAME="$1"
DOWNLOADS_ROOT="$2"
SRCDIR="$DOWNLOADS_ROOT/$NAME"
FAIL=0
CONVERTED=0
while IFS= read -r -d '' f; do
    tmp="${f%.flac}.m4a.tmp"
    out="${f%.flac}.m4a"
    if ffmpeg -nostdin -hide_banner -loglevel error -i "$f" -c:a alac -vn -f ipod "$tmp" </dev/null; then
        codec=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$tmp" 2>/dev/null)
        if [ "$codec" = "alac" ]; then
            mv -f "$tmp" "$out"
            rm -f "$f"
            CONVERTED=$((CONVERTED + 1))
        else
            rm -f "$tmp"
            echo "VERIFY_FAIL: $f" >&2
            FAIL=1
        fi
    else
        rm -f "$tmp"
        echo "CONVERT_FAIL: $f" >&2
        FAIL=1
    fi
done < <(find "$SRCDIR" -type f -iname '*.flac' -print0)
echo "CONVERTED=$CONVERTED"
exit $FAIL
CONVERT_SH
        )
        CONV_RC=$?

        if [ $CONV_RC -ne 0 ]; then
            log "FLAC conversion failed for $NAME: $CONV_OUT"
            mkdir -p "$REVIEW_DIR"
            printf '%s\n' "FLAC conversion failed" > "$SRC/.review-reason" 2>/dev/null || true
            mv -f "$SRC" "$REVIEW_DIR/" 2>/dev/null || log "ERROR: could not move $SRC to review"
            REVIEWED=$((REVIEWED + 1))
            ntfy "Review needed" "${NAME}: FLAC conversion failed" default "warning,musical_note"
            continue
        fi

        log "pre-conversion OK: $CONV_OUT"

        # Pre-sanitize m4a chapter atoms. Mac/Quicktime-ripped ALAC sometimes
        # has malformed `chpl` atoms that make mutagen (beets' metadata lib)
        # mark the file as "unreadable" — beets silently skips it and the
        # import sees a partial album. Lossless remux with ffmpeg fixes it.
        # See CLAUDE.md § "unreadable file ... MP4 chapter atoms".
        SANITIZE_OUT=$(docker exec -i -u "$BEETS_USER" "$BEETS_CONTAINER" bash -s "$NAME" "$CONTAINER_DOWNLOADS_ROOT" <<'SANITIZE_SH'
set -uo pipefail
NAME="$1"
DOWNLOADS_ROOT="$2"
SRCDIR="$DOWNLOADS_ROOT/$NAME"
FIXED=0
FAILED=0
while IFS= read -r -d '' f; do
    if python3 -c "from mutagen import File; File(\"$f\")" 2>/dev/null; then
        continue  # readable; leave alone
    fi
    tmp="${f%.m4a}.sanitize.m4a"
    if ffmpeg -nostdin -hide_banner -loglevel error -i "$f" -map_chapters -1 -c copy -f ipod "$tmp" </dev/null; then
        mv -f "$tmp" "$f"
        FIXED=$((FIXED + 1))
    else
        rm -f "$tmp"
        FAILED=$((FAILED + 1))
        echo "SANITIZE_FAIL: $f" >&2
    fi
done < <(find "$SRCDIR" -type f -iname '*.m4a' -print0)
echo "FIXED=$FIXED FAILED=$FAILED"
SANITIZE_SH
        )
        SANITIZE_RC=$?
        if [ "$SANITIZE_RC" -ne 0 ]; then
            log "WARN: m4a sanitize had failures for $NAME: $SANITIZE_OUT"
        elif [ -n "$SANITIZE_OUT" ] && ! [[ "$SANITIZE_OUT" =~ ^FIXED=0[[:space:]]FAILED=0$ ]]; then
            log "m4a sanitize: $SANITIZE_OUT"
        fi

        # Import with beets (quiet, timeout). Capture exit code so we can
        # distinguish "no match → review" from "timeout/crash → review".
        BEETS_OUT=$(docker exec -i -u "$BEETS_USER" "$BEETS_CONTAINER" bash -s "$BEETS_IMPORT_TIMEOUT" "$CONTAINER_DOWNLOADS_ROOT/$NAME" <<'IMPORT_SH'
timeout "$1" beet import -q -I -R "$2" 2>&1 </dev/null
IMPORT_SH
        )
        BEETS_RC=$?
        log "beets output (rc=$BEETS_RC): $BEETS_OUT"
        if [ "$BEETS_RC" -eq 124 ]; then
            log "WARN: beets import timed out after ${BEETS_IMPORT_TIMEOUT}s: $NAME"
        elif [ "$BEETS_RC" -ne 0 ]; then
            log "WARN: beets import exited with rc=$BEETS_RC: $NAME"
        fi

        # Success check: no audio files left in source
        audio_left=$(find "$SRC" -type f 2>/dev/null | grep -iE "$MUSIC_RE" | wc -l)
        is_duplicate=0
        if printf '%s' "$BEETS_OUT" | grep -q "already in the library"; then
            is_duplicate=1
        fi

        if [ "$audio_left" -eq 0 ]; then
            # Success — clean up remaining non-audio files
            log "beets import successful: $NAME"
            rm -rf "$SRC"
            IMPORTED=$((IMPORTED + 1))
            ntfy "Imported" "${NAME}" low "white_check_mark,musical_note"
            [ -n "${PC_ALBUMARTIST:-}" ] && LIDARR_NOTIFY_ARTISTS["$PC_ALBUMARTIST"]=1
        elif [ "$is_duplicate" -eq 1 ]; then
            # Beets says it's already in the library — delete source, don't review
            log "duplicate (already in library): $NAME — deleting source"
            rm -rf "$SRC"
            DUPLICATES=$((DUPLICATES + 1))
            ntfy "Duplicate skipped" "${NAME}" low "recycle,musical_note"
        else
            # Skipped or failed — move to review
            log "beets skipped/failed ($audio_left audio files remain): $NAME"
            mkdir -p "$REVIEW_DIR"
            printf '%s\n' "beets import skipped or failed (no strong MB match)" > "$SRC/.review-reason" 2>/dev/null || true
            mv -f "$SRC" "$REVIEW_DIR/" 2>/dev/null || log "ERROR: could not move $SRC to review"
            REVIEWED=$((REVIEWED + 1))
            ntfy "Review needed" "${NAME}: no strong MusicBrainz match" default "warning,musical_note"
        fi
        continue
    fi

    # === VIDEO FLOW ===
    if [ "$VIDEO_COUNT" -gt 0 ]; then
        lower_name=$(printf '%s' "$NAME" | tr '[:upper:]' '[:lower:]')
        if [[ "$lower_name" =~ $VIDEO_SERIES_RE ]]; then
            DEST="$MEDIA_DIR/Series"
        elif [[ "$lower_name" =~ $VIDEO_ANIME_RE ]]; then
            DEST="$MEDIA_DIR/Anime"
        else
            DEST="$MEDIA_DIR/Movies"
        fi
        log "detected video: $NAME → $DEST/"
        if mv -f "$SRC" "$DEST/" 2>>"$LOG"; then
            VIDEO_MOVED=$((VIDEO_MOVED + 1))
        else
            log "ERROR: mv failed for $NAME"
            FAILED=$((FAILED + 1))
            ntfy "Pipeline error" "mv failed: $NAME" high "x,musical_note"
        fi
        continue
    fi

    # === UNKNOWN ===
    log "UNKNOWN content type: $NAME (music=$MUSIC_COUNT video=$VIDEO_COUNT) — leaving in place"
    ntfy "Review needed" "Unknown content: $NAME" default "warning,musical_note"
done

# --- Report stuck torrents ---
if [ "${#STUCK[@]}" -gt 0 ]; then
    log "Stuck torrents (0% progress): ${#STUCK[@]}"
    for s in "${STUCK[@]}"; do log "  stuck: $s"; done
fi

# --- Notify Lidarr for each imported artist (best-effort, dedup'd) ---
if [ "${#LIDARR_NOTIFY_ARTISTS[@]}" -gt 0 ]; then
    log "lidarr: refreshing ${#LIDARR_NOTIFY_ARTISTS[@]} artist(s)"
    for artist in "${!LIDARR_NOTIFY_ARTISTS[@]}"; do
        lidarr_notify_artist "$artist"
    done
fi

# --- Summary + ntfy ---
SUMMARY="imported=$IMPORTED dup=$DUPLICATES review=$REVIEWED video_moved=$VIDEO_MOVED failed=$FAILED arr_skipped=$SKIPPED_ARR stuck=${#STUCK[@]} lidarr_notified=${#LIDARR_NOTIFY_ARTISTS[@]}"
log "=== pipeline run end: $SUMMARY ==="

if [ $((IMPORTED + REVIEWED + VIDEO_MOVED + FAILED + DUPLICATES)) -gt 0 ]; then
    ntfy "Pipeline run" "$SUMMARY" low "information_source,musical_note"
fi

exit 0
