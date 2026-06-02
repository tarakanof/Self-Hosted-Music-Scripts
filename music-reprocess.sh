#!/bin/bash
# music-reprocess.sh — manual cleanup for Lidarr-era FLAC albums in /Media/Music.
#
# Two phases:
#   A) dedup mixed-format (flac + m4a) album folders, codec-aware.
#   B) reprocess FLAC-only album folders in place (ffmpeg FLAC→ALAC + beet import).
#
# Does NOT modify music-pipeline.sh. Manual invocation only.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/config.sh"

# --- Configuration ---
LOG="${LOG:-$REPROCESS_LOG}"
LOCKFILE="${LOCKFILE:-$REPROCESS_LOCKFILE}"
DISC_PATTERN='^([0-9]+[\ ._-]*)?(CD|Disc|Disk|Vinyl|LP)[\ ._-]*[0-9]+$'

PHASE="all"
DRY_RUN=0
LIMIT=0

usage() {
    cat <<USAGE
Usage: $(basename "$0") [--phase a|b|all] [--dry-run] [--limit N] [-h|--help]

Manual reprocessing for Lidarr-era FLAC albums in $MUSIC_ROOT.

Phases:
  a      Dedup mixed-format (flac+m4a) album folders. Codec-aware.
  b      Reprocess FLAC-only album folders in place via ffmpeg + beet import.
  all    Run A then B. (default)

Options:
  --dry-run     Read-only. Classify and plan without modifying anything.
  --limit N     Process only the first N items of the active phase's
                candidate list, counted after multi-disc grouping.
  -h, --help    Show this help and exit.

Log:     $LOG
Backups: $BACKUP_ROOT/<date>/<slug>.tar (retained ${BACKUP_RETENTION_DAYS} days)
USAGE
}

# --- Argument parsing ---
while [ $# -gt 0 ]; do
    case "$1" in
        --phase)
            PHASE="${2:-}"
            shift 2
            ;;
        --phase=*)
            PHASE="${1#--phase=}"
            shift
            ;;
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --limit)
            LIMIT="${2:-0}"
            shift 2
            ;;
        --limit=*)
            LIMIT="${1#--limit=}"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf 'unknown argument: %s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

case "$PHASE" in
    a|b|all) ;;
    *)
        printf 'invalid --phase: %s (must be a, b, or all)\n' "$PHASE" >&2
        exit 2
        ;;
esac

case "$LIMIT" in
    ''|*[!0-9]*)
        printf 'invalid --limit: %s (must be a non-negative integer)\n' "$LIMIT" >&2
        exit 2
        ;;
esac

# --- Single-instance lock ---
exec 201>"$LOCKFILE"
if ! flock -n 201; then
    printf 'another music-reprocess.sh is already running (lock: %s)\n' "$LOCKFILE" >&2
    exit 1
fi

# --- Helpers ---
log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"
}

log_both() {
    # Write to log AND stdout so users can watch live.
    local msg
    msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
    printf '%s\n' "$msg" | tee -a "$LOG"
}

rotate_log() {
    if [ -f "$LOG" ] && [ "$(stat -c%s "$LOG" 2>/dev/null || echo 0)" -gt 10485760 ]; then
        mv -f "$LOG" "$LOG.1"
    fi
}

ntfy() {
    local title="$1" body="$2" prio="${3:-low}" tags="${4:-wrench,musical_note}"
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

host_to_container_path() {
    # /mnt/user/Media/Music/Foo/Bar → /music/Foo/Bar
    local host="$1"
    printf '%s\n' "${host/#$MUSIC_ROOT/$CONTAINER_MUSIC_ROOT}"
}

container_ffprobe() {
    # $1 = container path to audio file
    # remaining args = ffprobe options
    local cpath="$1"; shift
    docker exec -u "$BEETS_USER" "$BEETS_CONTAINER" ffprobe -v error "$@" "$cpath" 2>/dev/null
}

get_audio_codec() {
    # $1 = container path to audio file
    # Prints the first audio stream's codec_name (e.g. "alac", "aac", "flac").
    container_ffprobe "$1" \
        -select_streams a:0 \
        -show_entries stream=codec_name \
        -of default=nw=1:nk=1
}

# --- Phase A: dedup mixed-format folders ---

# Emit all folders under $MUSIC_ROOT that contain both .flac and .m4a files.
phase_a_find_mixed() {
    find "$MUSIC_ROOT" -type f \( -iname '*.flac' -o -iname '*.m4a' \) -printf '%h\n' \
        | sort -u \
        | while IFS= read -r dir; do
            local flac_count m4a_count
            flac_count=$(find "$dir" -maxdepth 1 -type f -iname '*.flac' 2>/dev/null | wc -l)
            m4a_count=$(find "$dir" -maxdepth 1 -type f -iname '*.m4a' 2>/dev/null | wc -l)
            if [ "$flac_count" -gt 0 ] && [ "$m4a_count" -gt 0 ]; then
                printf '%s\n' "$dir"
            fi
        done
}

# Determine the "kept format" for a mixed folder by ffprobing m4a codecs.
# Prints one of: "m4a" (all alac), "flac" (all aac), "ambiguous_codec"
phase_a_decide_kept() {
    local host_dir="$1"
    local saw_alac=0 saw_aac=0 saw_other=0
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        local cpath codec
        cpath=$(host_to_container_path "$f")
        codec=$(get_audio_codec "$cpath")
        case "$codec" in
            alac) saw_alac=1 ;;
            aac)  saw_aac=1 ;;
            *)    saw_other=1 ;;
        esac
    done < <(find "$host_dir" -maxdepth 1 -type f -iname '*.m4a' 2>/dev/null)

    if [ "$saw_other" = "1" ]; then
        printf 'ambiguous_codec\n'
    elif [ "$saw_alac" = "1" ] && [ "$saw_aac" = "0" ]; then
        printf 'm4a\n'
    elif [ "$saw_aac" = "1" ] && [ "$saw_alac" = "0" ]; then
        printf 'flac\n'
    else
        printf 'ambiguous_codec\n'
    fi
}

# Emit a TSV of (tracknum, title_lc, duration_int) for every audio file of the
# given extension in the folder. Sorted by tracknum. Used for comparison.
phase_a_track_metadata() {
    local host_dir="$1" ext="$2"
    find "$host_dir" -maxdepth 1 -type f -iname "*.$ext" 2>/dev/null | while IFS= read -r f; do
        [ -z "$f" ] && continue
        local cpath probe title duration track
        cpath=$(host_to_container_path "$f")
        probe=$(container_ffprobe "$cpath" \
            -show_entries format_tags=title,track:format=duration \
            -of default=nw=1) || continue
        # Normalize TAG keys to lowercase: FLAC stores TITLE/TRACK uppercase,
        # m4a stores title/track lowercase. ffprobe passes them through.
        probe=$(printf '%s\n' "$probe" | sed -E '/^TAG:/ s/^(TAG:)([^=]*)/\1\L\2/')
        title=$(printf '%s\n' "$probe" | sed -n 's/^TAG:title=//p' | head -1 | tr '[:upper:]' '[:lower:]' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
        track=$(printf '%s\n' "$probe" | sed -n 's/^TAG:track=//p' | head -1 | sed 's|/.*||' | sed 's/^0*//')
        duration=$(printf '%s\n' "$probe" | sed -n 's/^duration=//p' | head -1 | awk '{printf "%d\n", $1 + 0.5}')
        [ -z "$track" ] && track=0
        [ -z "$title" ] && title="(no title)"
        [ -z "$duration" ] && duration=0
        printf '%s\t%s\t%s\n' "$track" "$title" "$duration"
    done | sort -n
}

# Compare two TSVs (same format as phase_a_track_metadata output).
# Prints one of: "SAME", "DIFFERENT:<reason>", "AMBIGUOUS:<reason>".
phase_a_compare() {
    local flac_meta="$1" m4a_meta="$2"
    if [ -z "$flac_meta" ] || [ -z "$m4a_meta" ]; then
        printf 'AMBIGUOUS:one or both sides had no readable metadata\n'
        return
    fi
    local flac_count m4a_count
    flac_count=$(printf '%s\n' "$flac_meta" | grep -c '^')
    m4a_count=$(printf '%s\n' "$m4a_meta" | grep -c '^')
    if [ "$flac_count" -ne "$m4a_count" ]; then
        printf 'DIFFERENT:track count flac=%d m4a=%d\n' "$flac_count" "$m4a_count"
        return
    fi
    # Walk both lists in lockstep (already sorted by track num).
    local diff_reason=""
    while IFS= read -r fline <&3 && IFS= read -r mline <&4; do
        local ft fn fd mt mn md
        ft=$(printf '%s' "$fline" | cut -f1)
        fn=$(printf '%s' "$fline" | cut -f2)
        fd=$(printf '%s' "$fline" | cut -f3)
        mt=$(printf '%s' "$mline" | cut -f1)
        mn=$(printf '%s' "$mline" | cut -f2)
        md=$(printf '%s' "$mline" | cut -f3)
        if [ "$fn" != "$mn" ]; then
            diff_reason="title mismatch on track $ft: \"$fn\" vs \"$mn\""
            break
        fi
        local delta
        delta=$(( fd > md ? fd - md : md - fd ))
        if [ "$delta" -gt 2 ]; then
            diff_reason="duration delta ${delta}s on track $ft (\"$fn\")"
            break
        fi
    done 3< <(printf '%s\n' "$flac_meta") 4< <(printf '%s\n' "$m4a_meta")
    if [ -n "$diff_reason" ]; then
        printf 'DIFFERENT:%s\n' "$diff_reason"
        return
    fi
    printf 'SAME\n'
}

phase_a_delete_losing() {
    # Returns the deleted count on stdout — must NOT log to stdout or the
    # caller's capture gets corrupted. Use `log` (log-only) inside.
    local host_dir="$1" losing_ext="$2"
    local n=0
    while IFS= read -r f; do
        [ -z "$f" ] && continue
        if [ "$DRY_RUN" = "1" ]; then
            log "  [DRY-RUN] would rm: $f"
        else
            if rm -f "$f"; then
                n=$((n + 1))
            else
                log "  ERROR: rm failed: $f"
            fi
        fi
    done < <(find "$host_dir" -maxdepth 1 -type f -iname "*.$losing_ext" 2>/dev/null)
    printf '%d\n' "$n"
}

phase_a() {
    rotate_log
    log_both "=== phase A start (dry-run=$DRY_RUN limit=$LIMIT) ==="
    local count_total=0
    local count_same_m4a=0
    local count_same_flac=0
    local count_different=0
    local count_ambiguous=0
    local manual_review=()

    local processed=0
    while IFS= read -r dir; do
        [ -z "$dir" ] && continue
        count_total=$((count_total + 1))
        if [ "$LIMIT" -gt 0 ] && [ "$processed" -ge "$LIMIT" ]; then
            log_both "phase A: --limit $LIMIT reached, stopping"
            break
        fi
        processed=$((processed + 1))

        log_both "inspecting: $dir"
        local kept
        kept=$(phase_a_decide_kept "$dir")
        log_both "  kept format: $kept"

        if [ "$kept" = "ambiguous_codec" ]; then
            count_ambiguous=$((count_ambiguous + 1))
            manual_review+=("$dir — codec check failed (mixed or unknown codecs)")
            continue
        fi

        local flac_meta m4a_meta compare
        flac_meta=$(phase_a_track_metadata "$dir" flac)
        m4a_meta=$(phase_a_track_metadata "$dir" m4a)
        compare=$(phase_a_compare "$flac_meta" "$m4a_meta")
        log_both "  compare: $compare"

        case "$compare" in
            SAME)
                local losing deleted
                if [ "$kept" = "m4a" ]; then losing=flac; else losing=m4a; fi
                deleted=$(phase_a_delete_losing "$dir" "$losing")
                log_both "  deleted $deleted .$losing file(s)"
                if [ "$kept" = "m4a" ]; then
                    count_same_m4a=$((count_same_m4a + 1))
                else
                    count_same_flac=$((count_same_flac + 1))
                fi
                ;;
            DIFFERENT:*)
                count_different=$((count_different + 1))
                manual_review+=("$dir — ${compare#DIFFERENT:}")
                ;;
            AMBIGUOUS:*)
                count_ambiguous=$((count_ambiguous + 1))
                manual_review+=("$dir — ${compare#AMBIGUOUS:}")
                ;;
        esac
    done < <(phase_a_find_mixed)

    log_both "---"
    log_both "Phase A: $count_total folders inspected"
    log_both "  SAME_ALBUM (m4a kept, flac deleted): $count_same_m4a"
    log_both "  SAME_ALBUM (flac kept, m4a deleted): $count_same_flac"
    log_both "  DIFFERENT (manual review):           $count_different"
    log_both "  AMBIGUOUS (manual review):           $count_ambiguous"
    if [ "${#manual_review[@]}" -gt 0 ]; then
        log_both ""
        log_both "Manual review needed:"
        local r
        for r in "${manual_review[@]}"; do
            log_both "  - $r"
        done
    fi

    if [ "$DRY_RUN" != "1" ] && [ "$((count_same_m4a + count_same_flac + count_different + count_ambiguous))" -gt 0 ]; then
        local summary="inspected=$count_total same_m4a=$count_same_m4a same_flac=$count_same_flac diff=$count_different amb=$count_ambiguous"
        ntfy "Reprocess phase A" "$summary" low "wrench,musical_note"
    fi
}

# --- Phase B: reprocess FLAC-only albums in place ---

phase_b_find_candidates() {
    # Emit every folder that has at least one .flac and zero .m4a files.
    find "$MUSIC_ROOT" -type f \( -iname '*.flac' -o -iname '*.m4a' \) -printf '%h\n' \
        | sort -u \
        | while IFS= read -r dir; do
            local flac_count m4a_count
            flac_count=$(find "$dir" -maxdepth 1 -type f -iname '*.flac' 2>/dev/null | wc -l)
            m4a_count=$(find "$dir" -maxdepth 1 -type f -iname '*.m4a' 2>/dev/null | wc -l)
            if [ "$flac_count" -gt 0 ] && [ "$m4a_count" -eq 0 ]; then
                printf '%s\n' "$dir"
            fi
        done
}

# Apply multi-disc grouping to a newline-separated candidate list on stdin.
# Emits two streams on stdout, tab-delimited:
#   CANDIDATE\t<host_path>
#   MANUAL\t<reason>\t<host_path>
# All-or-nothing promotion — see spec for the rule.
phase_b_group_multidisc() {
    local -a candidates=()
    local line
    while IFS= read -r line; do
        [ -n "$line" ] && candidates+=("$line")
    done

    # Pass 1: identify disc folders and group by parent.
    declare -A disc_parents=()       # parent → newline-separated disc children
    declare -A non_disc_candidates=() # host_path → 1 (non-disc candidates pass through)
    local c
    for c in "${candidates[@]}"; do
        local base
        base=$(basename "$c")
        if [[ "$base" =~ $DISC_PATTERN ]]; then
            local parent
            parent=$(dirname "$c")
            disc_parents["$parent"]="${disc_parents[$parent]:-}${c}"$'\n'
        else
            non_disc_candidates["$c"]=1
        fi
    done

    # Pass 2: for each parent with disc children, decide promote vs manual review.
    local parent
    for parent in "${!disc_parents[@]}"; do
        local children_list="${disc_parents[$parent]}"
        local n_candidate_discs
        n_candidate_discs=$(printf '%s' "$children_list" | grep -c '^' || true)

        # Rule 1: parent must have no audio files at its own root.
        local parent_audio
        parent_audio=$(find "$parent" -maxdepth 1 -type f 2>/dev/null \
            | grep -ciE "$MUSIC_RE" || true)
        if [ "$parent_audio" -gt 0 ]; then
            local c2
            while IFS= read -r c2; do
                [ -n "$c2" ] && printf 'MANUAL\tparent has root-level audio\t%s\n' "$c2"
            done <<<"$children_list"
            continue
        fi

        # Enumerate every immediate subfolder of the parent.
        local -a parent_children=()
        while IFS= read -r p; do
            [ -n "$p" ] && parent_children+=("$p")
        done < <(find "$parent" -mindepth 1 -maxdepth 1 -type d 2>/dev/null)

        # Rule 2: every immediate subfolder must match the disc pattern.
        local all_disc=1 sub
        for sub in "${parent_children[@]}"; do
            local sub_base
            sub_base=$(basename "$sub")
            if ! [[ "$sub_base" =~ $DISC_PATTERN ]]; then
                all_disc=0
                break
            fi
        done
        if [ "$all_disc" = "0" ]; then
            local c3
            while IFS= read -r c3; do
                [ -n "$c3" ] && printf 'MANUAL\tparent has non-disc subfolders\t%s\n' "$c3"
            done <<<"$children_list"
            continue
        fi

        # Rule 3: every disc subfolder must be in the candidate set (flac-only).
        if [ "${#parent_children[@]}" -ne "$n_candidate_discs" ]; then
            local c4
            while IFS= read -r c4; do
                [ -n "$c4" ] && printf 'MANUAL\tat least one disc already has m4a\t%s\n' "$c4"
            done <<<"$children_list"
            continue
        fi

        # All three rules passed — promote the parent.
        printf 'CANDIDATE\t%s\n' "$parent"
    done

    # Non-disc candidates pass through unchanged.
    local nd
    for nd in "${!non_disc_candidates[@]}"; do
        printf 'CANDIDATE\t%s\n' "$nd"
    done
}

phase_b_slug() {
    # $1 = relpath under $MUSIC_ROOT, e.g. "Moby/Future Quiet (2026)"
    local rel="$1"
    local slug
    slug="${rel//\//__}"                                  # / → __
    slug=$(printf '%s' "$slug" | tr -s '[:space:]' '_')   # whitespace runs → _
    slug=$(printf '%s' "$slug" | sed 's/_$//')            # trim trailing _
    if [ -z "$slug" ]; then
        slug="album-$(date +%s)-$RANDOM"
    fi
    printf '%s\n' "$slug"
}

phase_b_check_stale() {
    # $1 = absolute host path to album folder
    # Returns 0 if clean, 1 if stale .m4a.tmp files present.
    local host_dir="$1"
    if find "$host_dir" -type f -iname '*.m4a.tmp' 2>/dev/null | grep -q .; then
        return 1
    fi
    return 0
}

phase_b_backup() {
    # $1 = absolute host path to album folder
    # $2 = slug
    # Prints the backup path on success (nothing else — callers capture stdout),
    # or returns non-zero on failure.
    local host_dir="$1" slug="$2"
    local rel="${host_dir#$MUSIC_ROOT/}"
    local date_dir
    date_dir="$BACKUP_ROOT/$(date +%Y-%m-%d)"
    mkdir -p "$date_dir" || return 1
    chmod 700 "$BACKUP_ROOT" 2>/dev/null
    chmod 700 "$date_dir" 2>/dev/null
    local backup_path="$date_dir/${slug}.tar"
    if [ -f "$backup_path" ]; then
        log "  backup already exists, keeping prior: $backup_path"
        printf '%s\n' "$backup_path"
        return 0
    fi
    if tar -cf "$backup_path" -C "$MUSIC_ROOT" "$rel" 2>>"$LOG"; then
        log "  backup: $backup_path ($(du -h "$backup_path" | awk '{print $1}'))"
        printf '%s\n' "$backup_path"
    else
        log "  ERROR: tar -cf failed for $host_dir"
        rm -f "$backup_path"
        return 1
    fi
}

phase_b_prune_old_backups() {
    if [ ! -d "$BACKUP_ROOT" ]; then
        return 0
    fi
    local n
    n=$(find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -mtime "+${BACKUP_RETENTION_DAYS}" 2>/dev/null | wc -l)
    if [ "$n" -gt 0 ]; then
        log_both "pruning $n backup dir(s) older than ${BACKUP_RETENTION_DAYS} days"
        if [ "$DRY_RUN" != "1" ]; then
            find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -mtime "+${BACKUP_RETENTION_DAYS}" -exec rm -rf {} \;
        fi
    fi
}

# Dumps all album rows from the beets DB in a single call.
# Format per line: "<id>|||<container_path>"
phase_b_dump_beets_albums() {
    docker exec -u "$BEETS_USER" "$BEETS_CONTAINER" beet ls -a -f '$id|||$path' 2>/dev/null || true
}

# $1 = container path, $2 = dumped DB (ALL_ALBUMS)
# Prints matching album id, or empty.
phase_b_find_db_id() {
    local cpath="$1" dump="$2"
    printf '%s\n' "$dump" \
        | awk -F'\\|\\|\\|' -v p="$cpath" '$2 == p {print $1; exit}'
}

phase_b_remove_db_entry() {
    local id="$1"
    if [ -z "$id" ]; then
        return 0
    fi
    docker exec -u "$BEETS_USER" "$BEETS_CONTAINER" beet rm -a -f "id:$id" >>"$LOG" 2>&1
}

# Restores an album folder from its tar backup.
# $1 = relpath under $MUSIC_ROOT, $2 = backup_path
phase_b_restore() {
    local rel="$1" backup_path="$2"
    if [ ! -f "$backup_path" ]; then
        log_both "  ERROR: cannot restore — backup missing: $backup_path"
        return 1
    fi
    rm -rf "$MUSIC_ROOT/$rel"
    if tar -xf "$backup_path" -C "$MUSIC_ROOT" 2>>"$LOG"; then
        log_both "  restored from backup: $backup_path"
        return 0
    else
        log_both "  ERROR: tar -xf failed: $backup_path"
        return 1
    fi
}

# All-or-nothing in-place FLAC → ALAC conversion inside the beets container.
# $1 = relpath under /music
# Returns 0 on success, non-zero on any failure.
phase_b_convert_flac() {
    local rel="$1"
    docker exec -i -u "$BEETS_USER" "$BEETS_CONTAINER" bash -s "$rel" "$CONTAINER_MUSIC_ROOT" <<'CONVERT_SH' >>"$LOG" 2>&1
set -uo pipefail
REL="$1"
MUSIC_ROOT="$2"
SRCDIR="$MUSIC_ROOT/$REL"
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
}

# Snapshots beets album paths scoped to a single artist prefix.
# $1 = artist prefix (e.g. "/music/Moby/")
# Prints sorted paths, one per line.
phase_b_artist_paths() {
    local prefix="$1"
    docker exec -u "$BEETS_USER" "$BEETS_CONTAINER" beet ls -a -f '$path' 2>/dev/null \
        | grep -F "$prefix" \
        | sort
}

# Snapshots host-side artist directory children (immediate subdirs only).
# $1 = host artist dir
phase_b_artist_dirs() {
    local artist_dir="$1"
    find "$artist_dir" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort
}

# Runs beet import on an in-place relpath. Captures output and rc globally.
# Sets globals: BEETS_OUT, BEETS_RC
# $1 = relpath under /music
phase_b_beet_import() {
    local rel="$1"
    BEETS_OUT=$(docker exec -i -u "$BEETS_USER" "$BEETS_CONTAINER" bash -s "$BEETS_IMPORT_TIMEOUT" "$CONTAINER_MUSIC_ROOT/$rel" <<'IMPORT_SH'
timeout "$1" beet import -q -I -R "$2" 2>&1 </dev/null
IMPORT_SH
    )
    BEETS_RC=$?
}

# Cleanup-then-restore for rc=4 (beets crash/timeout, unknown state).
# $1 = relpath, $2 = backup_path, $3 = artist_dir_host, $4 = dir_before (newline-sep)
phase_b_cleanup_restore() {
    local rel="$1" backup_path="$2" artist_dir_host="$3" dir_before="$4"
    log_both "  rc=4 cleanup: diffing artist dir against pre-import snapshot"
    local dir_after
    dir_after=$(phase_b_artist_dirs "$artist_dir_host")
    local new_dirs
    new_dirs=$(comm -13 <(printf '%s\n' "$dir_before") <(printf '%s\n' "$dir_after"))
    if [ -n "$new_dirs" ]; then
        log_both "  removing beets-created sibling dir(s):"
        local d
        while IFS= read -r d; do
            [ -n "$d" ] && log_both "    rm -rf $d" && rm -rf "$d"
        done <<<"$new_dirs"
    fi
    if [ -d "$MUSIC_ROOT/$rel" ]; then
        rm -rf "$MUSIC_ROOT/$rel"
    fi
    phase_b_restore "$rel" "$backup_path"
}

phase_b() {
    rotate_log
    log_both "=== phase B start (dry-run=$DRY_RUN limit=$LIMIT) ==="

    local -a candidates=()
    local -a manual_review=()
    local line kind payload path reason
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        kind=$(printf '%s' "$line" | cut -f1)
        case "$kind" in
            CANDIDATE)
                path=$(printf '%s' "$line" | cut -f2)
                candidates+=("$path")
                ;;
            MANUAL)
                reason=$(printf '%s' "$line" | cut -f2)
                path=$(printf '%s' "$line" | cut -f3)
                manual_review+=("$path — $reason")
                ;;
        esac
    done < <(phase_b_find_candidates | phase_b_group_multidisc | sort)

    log_both "phase B: ${#candidates[@]} candidate(s) after multi-disc grouping"
    log_both "phase B: ${#manual_review[@]} multi-disc manual-review item(s)"

    if [ "${#candidates[@]}" -eq 0 ] && [ "${#manual_review[@]}" -eq 0 ]; then
        log_both "phase B: nothing to do"
        return 0
    fi

    phase_b_prune_old_backups

    local ALL_ALBUMS=""
    if [ "$DRY_RUN" = "1" ]; then
        log_both "dry-run: skipping live DB operations (beet ls still read-only, skipped for speed)"
    else
        log_both "dumping beets DB album list..."
        ALL_ALBUMS=$(phase_b_dump_beets_albums)
        log_both "beets DB: $(printf '%s\n' "$ALL_ALBUMS" | grep -c '^') album(s)"
    fi

    local count_imported=0
    local count_duplicate=0
    local count_no_match=0
    local count_conv_failed=0
    local count_stale=0
    local -a new_paths_list=()
    local -a no_match_list=()
    local -a failed_list=()

    local processed=0 rel host_dir slug backup_path
    for host_dir in "${candidates[@]}"; do
        if [ "$LIMIT" -gt 0 ] && [ "$processed" -ge "$LIMIT" ]; then
            log_both "phase B: --limit $LIMIT reached, stopping"
            break
        fi
        processed=$((processed + 1))

        rel="${host_dir#$MUSIC_ROOT/}"
        log_both "processing: $rel"

        if ! phase_b_check_stale "$host_dir"; then
            log_both "  STALE_ARTIFACTS: found .m4a.tmp file(s), skipping"
            count_stale=$((count_stale + 1))
            continue
        fi

        slug=$(phase_b_slug "$rel")
        log_both "  slug: $slug"

        if [ "$DRY_RUN" = "1" ]; then
            log_both "  [DRY-RUN] would tar -> $BACKUP_ROOT/$(date +%Y-%m-%d)/${slug}.tar"
            log_both "  [DRY-RUN] would beet rm + convert + import"
            continue
        fi

        backup_path=$(phase_b_backup "$host_dir" "$slug")
        if [ -z "$backup_path" ]; then
            log_both "  ERROR: backup failed, skipping album"
            count_conv_failed=$((count_conv_failed + 1))
            failed_list+=("$rel — backup failed")
            continue
        fi
        log_both "  backup: $backup_path"

        local container_path db_id
        container_path=$(host_to_container_path "$host_dir")
        db_id=$(phase_b_find_db_id "$container_path" "$ALL_ALBUMS")
        if [ -n "$db_id" ]; then
            log_both "  removing stale beets DB entry: id=$db_id"
            phase_b_remove_db_entry "$db_id"
        else
            log_both "  no prior beets DB entry found for $container_path"
        fi

        log_both "  converting FLAC → ALAC..."
        if ! phase_b_convert_flac "$rel"; then
            log_both "  CONVERT_FAIL — restoring from backup"
            phase_b_restore "$rel" "$backup_path"
            count_conv_failed=$((count_conv_failed + 1))
            failed_list+=("$rel — conversion failed")
            continue
        fi
        log_both "  conversion OK"

        # Pre-import snapshots
        local artist_prefix artist_dir_host paths_before dir_before
        artist_prefix="$CONTAINER_MUSIC_ROOT/$(dirname "$rel")/"
        artist_dir_host="$MUSIC_ROOT/$(dirname "$rel")"
        paths_before=$(phase_b_artist_paths "$artist_prefix")
        dir_before=$(phase_b_artist_dirs "$artist_dir_host")

        # Import
        log_both "  running beet import..."
        local BEETS_OUT="" BEETS_RC=0
        phase_b_beet_import "$rel"
        log_both "  beet import rc=$BEETS_RC"

        # Post-import snapshot
        local paths_after new_paths
        paths_after=$(phase_b_artist_paths "$artist_prefix")
        new_paths=$(comm -13 <(printf '%s\n' "$paths_before") <(printf '%s\n' "$paths_after"))

        # Outcome dispatch.
        # Check new_paths FIRST: a successful import can return rc=1 with
        # non-fatal warnings (e.g. unreadable art files, tag warnings) and we
        # still want to credit it as IMPORTED. Only treat empty new_paths +
        # non-zero rc as a real failure.
        if [ -n "$new_paths" ]; then
            log_both "  IMPORTED: new path(s):"
            local np
            while IFS= read -r np; do
                [ -n "$np" ] && log_both "    $np" && new_paths_list+=("$np")
            done <<<"$new_paths"
            count_imported=$((count_imported + 1))
            if [ "$BEETS_RC" -ne 0 ]; then
                log_both "  (beets returned rc=$BEETS_RC but a new album was registered — treating as success)"
                printf '%s\n' "$BEETS_OUT" | tail -5 >> "$LOG"
            fi
        elif [ "$BEETS_RC" -eq 124 ]; then
            log_both "  TIMEOUT after ${BEETS_IMPORT_TIMEOUT}s — cleanup + restore"
            printf '%s\n' "$BEETS_OUT" | tail -20 >> "$LOG"
            phase_b_cleanup_restore "$rel" "$backup_path" "$artist_dir_host" "$dir_before"
            count_conv_failed=$((count_conv_failed + 1))
            failed_list+=("$rel — timeout")
        elif [ "$BEETS_RC" -ne 0 ]; then
            log_both "  BEETS_CRASH rc=$BEETS_RC — cleanup + restore"
            printf '%s\n' "$BEETS_OUT" | tail -20 >> "$LOG"
            phase_b_cleanup_restore "$rel" "$backup_path" "$artist_dir_host" "$dir_before"
            count_conv_failed=$((count_conv_failed + 1))
            failed_list+=("$rel — beets rc=$BEETS_RC")
        elif printf '%s' "$BEETS_OUT" | grep -q 'already in the library'; then
            log_both "  DUPLICATE: beets matched to an existing album"
            count_duplicate=$((count_duplicate + 1))
        else
            log_both "  NEEDS_MANUAL_MATCH: beets could not find a strong match — album left in place"
            count_no_match=$((count_no_match + 1))
            no_match_list+=("$rel")
        fi
    done

    log_both "---"
    log_both "Phase B: $processed candidate(s) processed (after multi-disc grouping)"
    log_both "  Imported:            $count_imported"
    log_both "  Duplicate:           $count_duplicate"
    log_both "  Needs manual match:  $count_no_match"
    log_both "  Conv/import failed:  $count_conv_failed"
    log_both "  Stale artifacts:     $count_stale"
    if [ "${#new_paths_list[@]}" -gt 0 ]; then
        log_both ""
        log_both "Imported (new paths):"
        local np
        for np in "${new_paths_list[@]}"; do
            log_both "  $np"
        done
    fi
    if [ "${#manual_review[@]}" -gt 0 ]; then
        log_both ""
        log_both "Manual review (multi-disc grouping):"
        local r
        for r in "${manual_review[@]}"; do
            log_both "  - $r"
        done
    fi
    if [ "${#no_match_list[@]}" -gt 0 ]; then
        log_both ""
        log_both "Needs manual match (left in place in $MUSIC_ROOT):"
        local nm
        for nm in "${no_match_list[@]}"; do
            log_both "  - $nm"
        done
    fi
    if [ "${#failed_list[@]}" -gt 0 ]; then
        log_both ""
        log_both "Auto-restored (conv/import failed):"
        local fl
        for fl in "${failed_list[@]}"; do
            log_both "  - $fl"
        done
    fi

    if [ "$DRY_RUN" != "1" ]; then
        local summary="imported=$count_imported dup=$count_duplicate manual=$count_no_match failed=$count_conv_failed stale=$count_stale"
        ntfy "Reprocess phase B" "$summary" low "wrench,musical_note"
    fi
}

# --- Main dispatch ---
case "$PHASE" in
    a)   phase_a ;;
    b)   phase_b ;;
    all) phase_a; phase_b ;;
esac

exit 0
