#!/bin/bash
# music-cue-split.sh — Split single-file CUE+image albums into per-track FLAC.
#
# Decodes FLAC, APE (Monkey's Audio), and WavPack (.wv) sources via ffmpeg in
# the beets container. Outputs sample-accurate per-track FLAC alongside the
# source. Original image + cue are moved to ./.cue-source-backup/ so re-runs
# are idempotent and the original is recoverable.
#
# After running, the resulting per-track FLAC is ready for the standard
# music-pipeline.sh FLAC→ALAC convert + beet import flow.
#
# Usage:
#   music-cue-split.sh /mnt/user/Torrents/complete/<dir>     # split in place
#   music-cue-split.sh -n /mnt/user/Torrents/complete/<dir>  # dry-run (parse only)
#
# Multi-disc handling: if no cue lives at the top level, every subdir (other
# than Scans/scans/cover/.*) is processed independently. Each disc becomes its
# own beets album on import; consolidate later via the consolidate-album-pair
# skill if desired.

set -uo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/config.sh"

DRY_RUN=0
while [ $# -gt 0 ]; do
    case "$1" in
        -n|--dry-run) DRY_RUN=1; shift ;;
        -h|--help) sed -n '2,/^$/ { /^$/q; s/^# \?//p }' "$0"; exit 0 ;;
        --) shift; break ;;
        -*) echo "Unknown option: $1" >&2; exit 2 ;;
        *) break ;;
    esac
done

TARGET="${1:-}"
[ -z "$TARGET" ] && { echo "Usage: $0 [-n] <dir>" >&2; exit 2; }
[ -d "$TARGET" ] || { echo "Not a directory: $TARGET" >&2; exit 2; }

# Map host path → container /downloads path
case "$TARGET" in
    "$HOST_COMPLETE"/*)
        CT_TARGET="$CONTAINER_DOWNLOADS_ROOT/${TARGET#"$HOST_COMPLETE"/}"
        ;;
    "$CONTAINER_DOWNLOADS_ROOT"/*)
        CT_TARGET="$TARGET"
        ;;
    *)
        echo "Path must be under $HOST_COMPLETE (or $CONTAINER_DOWNLOADS_ROOT for container paths)" >&2
        exit 2
        ;;
esac

docker exec -i -u "$BEETS_USER" "$BEETS_CONTAINER" bash -s -- "$CT_TARGET" "$DRY_RUN" <<'CONTAINER_SH'
set -uo pipefail
TARGET="$1"
DRY_RUN="$2"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

# Convert cue MM:SS:FF to seconds (75 frames/sec).
cue_to_seconds() {
    awk -F: -v t="$1" 'BEGIN { split(t, p, ":"); printf "%.6f\n", p[1]*60 + p[2] + p[3]/75 }'
}

normalize_cue() {
    # Detect encoding via strict Python decode (iconv's UTF-8 check is too
    # lenient — passes CP1251 files that strict Python rejects). Fallback
    # order: utf-8-sig → utf-8 → cp1251 → koi8-r → latin-1. CRLF → LF.
    local in="$1" out="$2"
    python3 - "$in" "$out" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
data = open(src, "rb").read()
for enc in ("utf-8-sig", "utf-8", "cp1251", "koi8-r", "latin-1"):
    try:
        text = data.decode(enc, errors="strict")
        break
    except UnicodeDecodeError:
        continue
else:
    text = data.decode("utf-8", errors="replace")
text = text.replace("\r\n", "\n").replace("\r", "\n")
open(dst, "w", encoding="utf-8").write(text)
PY
}

split_dir() {
    local dir="$1"

    # Idempotency: skip if already split (backup dir present at top level).
    if [ -d "$dir/.cue-source-backup" ]; then
        log "skip $(basename "$dir") (already split — .cue-source-backup exists)"
        return 0
    fi

    # First pass: collect valid (cue, image, normalized-cue) tuples. Skip cues
    # without a FILE directive or whose referenced image is missing (handles
    # EAC-style cues that point at .wav while the real audio is .flac/.ape/.wv,
    # plus stale duplicate cues left alongside the working one).
    local -a cue_list=() image_list=() norm_list=()
    local cue file_ref image base alt cue_norm
    while IFS= read -r cue; do
        cue_norm=$(mktemp)
        normalize_cue "$cue" "$cue_norm"
        file_ref=$(awk '
            /^FILE / {
                match($0, /"[^"]*"/)
                if (RSTART > 0) {
                    print substr($0, RSTART+1, RLENGTH-2); exit
                }
            }' "$cue_norm")
        if [ -z "$file_ref" ]; then
            log "  cue has no FILE directive: $(basename "$cue") — skip"
            rm -f "$cue_norm"; continue
        fi
        image="$dir/$file_ref"
        if [ ! -f "$image" ]; then
            # m4a included for sources where music-pipeline.sh's FLAC→ALAC
            # pre-conversion ran on a single-file FLAC image and produced an
            # m4a (ALAC) image alongside the original cue (which still points
            # at the .flac/.wav name).
            base="${file_ref%.*}"
            for ext in flac ape wv m4a FLAC APE WV M4A; do
                alt="$dir/${base}.${ext}"
                if [ -f "$alt" ]; then image="$alt"; break; fi
            done
        fi
        if [ ! -f "$image" ]; then
            log "  cue refs missing image ($file_ref): $(basename "$cue") — skip"
            rm -f "$cue_norm"; continue
        fi
        cue_list+=("$cue")
        image_list+=("$image")
        norm_list+=("$cue_norm")
    done < <(find "$dir" -maxdepth 1 -type f -iname "*.cue" | sort)

    local n_pairs=${#cue_list[@]}
    if [ "$n_pairs" -eq 0 ]; then
        log "no valid cue+image pair in $dir"
        return 0
    fi

    # Multi-pair: write each pair's output to a subdir keyed off the cue's
    # basename so per-track filenames don't share a namespace and clobber each
    # other (the БИ 2 SPIRIT case: main album + bonus CD with overlapping
    # track numbers in the same dir). Single-pair: write directly to $dir.
    local i=0 out_dir cue_base rc
    rc=0
    while [ $i -lt $n_pairs ]; do
        if [ "$n_pairs" -gt 1 ]; then
            cue_base=$(basename "${cue_list[$i]}")
            cue_base="${cue_base%.[Cc][Uu][Ee]}"
            cue_base="${cue_base//\//_}"
            out_dir="$dir/$cue_base"
            [ "$DRY_RUN" = "1" ] || mkdir -p "$out_dir"
        else
            out_dir="$dir"
        fi
        if ! split_pair "$out_dir" "${cue_list[$i]}" "${image_list[$i]}" "${norm_list[$i]}"; then
            rc=1
        fi
        rm -f "${norm_list[$i]}"
        i=$((i+1))
    done

    # Multi-pair: aux files (logs/auCDtect/accurip at top level) are
    # whole-torrent metadata; stash them in a top-level backup so re-runs hit
    # the idempotency check. If there were no aux files, drop a placeholder.
    if [ "$n_pairs" -gt 1 ] && [ "$DRY_RUN" != "1" ] && [ "$rc" -eq 0 ]; then
        local backup="$dir/.cue-source-backup"
        local moved=0
        while IFS= read -r aux; do
            [ -f "$aux" ] || continue
            mkdir -p "$backup"
            mv "$aux" "$backup/"
            moved=$((moved+1))
        done < <(find "$dir" -maxdepth 1 -type f \
            \( -iname "*.log" -o -iname "*.auCDtect.txt" -o -iname "*.accurip" \) 2>/dev/null)
        if [ "$moved" -eq 0 ] && [ ! -d "$backup" ]; then
            mkdir -p "$backup"
            : > "$backup/.placeholder"
        fi
    fi

    return "$rc"
}

split_pair() {
    local dir="$1" cue="$2" image="$3" cue_norm="$4"

    log "split: $(basename "$dir")"
    log "  cue:   $(basename "$cue")"
    log "  image: $(basename "$image")"

    # Album-level title/performer (first TITLE/PERFORMER before any TRACK line).
    local album_title album_perf
    album_title=$(awk -F\" '
        /^[[:space:]]*TRACK/ { exit }
        /^[[:space:]]*TITLE/ && !found { print $2; found=1 }
    ' "$cue_norm")
    album_perf=$(awk -F\" '
        /^[[:space:]]*TRACK/ { exit }
        /^[[:space:]]*PERFORMER/ && !found { print $2; found=1 }
    ' "$cue_norm")

    log "  album: ${album_perf:-?} / ${album_title:-?}"

    # Per-track parse → tab-separated: no \t title \t performer \t MM:SS:FF
    local tracks
    tracks=$(mktemp)
    awk -F\" '
        /^[[:space:]]*TRACK[[:space:]]+[0-9]+[[:space:]]+AUDIO/ {
            if (cur != "") print cur "\t" t "\t" p "\t" idx
            n = $0; sub(/^[[:space:]]*TRACK[[:space:]]+/, "", n); sub(/[[:space:]]+AUDIO.*/, "", n)
            cur = n; t = ""; p = ""; idx = ""
        }
        /^[[:space:]]+TITLE/     { t = $2 }
        /^[[:space:]]+PERFORMER/ { p = $2 }
        /^[[:space:]]+INDEX[[:space:]]+01[[:space:]]/ {
            match($0, /[0-9]+:[0-9]+:[0-9]+/); if (RSTART > 0) idx = substr($0, RSTART, RLENGTH)
        }
        END { if (cur != "") print cur "\t" t "\t" p "\t" idx }
    ' "$cue_norm" > "$tracks"

    local n_tracks
    n_tracks=$(wc -l < "$tracks" | tr -d ' ')
    log "  tracks: $n_tracks"

    if [ "$DRY_RUN" = "1" ]; then
        sed 's/^/    /' "$tracks"
        rm -f "$cue_norm" "$tracks"
        return 0
    fi

    # Extract: needs current start + next start to compute duration.
    local lines=()
    while IFS= read -r line; do lines+=("$line"); done < "$tracks"

    local i=0 fail=0
    while [ $i -lt ${#lines[@]} ]; do
        IFS=$'\t' read -r no title perf idx <<< "${lines[$i]}"
        local start_s end_arg=""
        start_s=$(cue_to_seconds "$idx")
        if [ $((i+1)) -lt ${#lines[@]} ]; then
            local nxt_idx
            nxt_idx=$(echo "${lines[$((i+1))]}" | awk -F'\t' '{print $4}')
            local end_s
            end_s=$(cue_to_seconds "$nxt_idx")
            end_arg="-to $end_s"
        fi

        local artist="${perf:-$album_perf}"
        # Force base-10: printf "%02d" 08 fails because bash treats 0-prefixed
        # numbers as octal and 8 isn't a valid octal digit.
        local pad_no
        pad_no=$(printf "%02d" "$((10#$no))")
        # Sanitize filename — only / and NUL really break paths.
        local safe_title="${title//\//_}"
        local out="$dir/${pad_no} ${safe_title}.flac"

        if ffmpeg -nostdin -hide_banner -loglevel error \
            -i "$image" -ss "$start_s" $end_arg \
            -map_metadata -1 \
            -metadata "title=$title" \
            -metadata "artist=$artist" \
            -metadata "albumartist=${album_perf:-$artist}" \
            -metadata "album=$album_title" \
            -metadata "track=$no/$n_tracks" \
            -c:a flac \
            "$out" </dev/null 2>&1; then
            log "    ✓ $pad_no  $title"
        else
            log "    ✗ $pad_no  $title (ffmpeg failed)"
            fail=$((fail+1))
        fi
        i=$((i+1))
    done

    if [ "$fail" -gt 0 ]; then
        log "  $fail failure(s) — leaving source in place for retry"
        rm -f "$cue_norm" "$tracks"
        return 1
    fi

    # Success: stash source image + cue in .cue-source-backup.
    local backup="$dir/.cue-source-backup"
    mkdir -p "$backup"
    mv "$image" "$backup/"
    mv "$cue"   "$backup/"
    # Move logs/auCDtect/accurip alongside the cue if present.
    while IFS= read -r aux; do
        [ -f "$aux" ] && mv "$aux" "$backup/"
    done < <(find "$dir" -maxdepth 1 -type f \
        \( -iname "*.log" -o -iname "*.auCDtect.txt" -o -iname "*.accurip" \) 2>/dev/null)

    log "  done: source moved to .cue-source-backup/"
    rm -f "$cue_norm" "$tracks"
}

# Top-level cue → single-disc; otherwise walk subdirs.
top_cue=$(find "$TARGET" -maxdepth 1 -type f -iname "*.cue" | head -1)
if [ -n "$top_cue" ]; then
    split_dir "$TARGET"
else
    log "no top-level cue — walking subdirs"
    while IFS= read -r sub; do
        case "$(basename "$sub")" in
            Scans|scans|Cover|cover|сканы|.*) log "skip $(basename "$sub")"; continue ;;
        esac
        split_dir "$sub"
    done < <(find "$TARGET" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
fi
CONTAINER_SH
