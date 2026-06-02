#!/bin/bash
# music-lidarr-sync.sh — Phase 1 read-only audit of beets ↔ Lidarr drift.
# See docs/plans/2026-04-19-lidarr-beets-sync.md for design.
#
# Outputs:
#   - report log: $LOG (append, full detail)
#   - snapshot:   $REPORT_TSV (this run only, diffable)
#   - ntfy:       summary line per run
#
# Phase 1 is DRY-RUN only. No writes to Lidarr or beets.

set -u
shopt -s extglob

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck disable=SC1091
. "$SCRIPT_DIR/lib/config.sh"

# ----- config -----
LOG="${LOG:-$LIDARR_SYNC_LOG}"
REPORT_TSV="${REPORT_TSV:-$LIDARR_SYNC_REPORT_TSV}"
LOCK="$LIDARR_SYNC_LOCKFILE"
PIPELINE_LOCK="$PIPELINE_LOCKFILE"

# ----- helpers -----
log()  { printf '[%s] %s\n' "$(date '+%F %T')" "$*" >> "$LOG"; }
err()  { log "ERROR: $*"; printf 'ERROR: %s\n' "$*" >&2; }
ntfy() {
    local title="$1" body="$2" prio="${3:-default}" tags="${4:-musical_note}"
    local token=""
    [ -r "$NTFY_TOKEN_FILE" ] && token=$(head -1 "$NTFY_TOKEN_FILE")
    curl -s -o /dev/null -X POST \
        -H "Title: $title" -H "Priority: $prio" -H "Tags: $tags" \
        ${token:+-H "Authorization: Bearer $token"} \
        --data "$body" "$NTFY_URL" || true
}

# ----- prelude -----
if [ -e "$LOCK" ]; then
    err "lock exists: $LOCK; aborting"; exit 0
fi
echo $$ > "$LOCK"
trap 'rm -f "$LOCK"' EXIT

if [ -e "$PIPELINE_LOCK" ]; then
    pid=$(cat "$PIPELINE_LOCK" 2>/dev/null)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
        log "music-pipeline.sh holds lock (pid $pid) — skipping this tick"; exit 0
    else
        log "stale pipeline lock; ignoring"
    fi
fi

[ -r "$LIDARR_KEY_FILE" ] || { err "no Lidarr key at $LIDARR_KEY_FILE"; exit 1; }
KEY=$(head -1 "$LIDARR_KEY_FILE")

status=$(curl -s -o /dev/null -w '%{http_code}' -H "X-Api-Key: $KEY" "$LIDARR_URL/api/v1/system/status")
if [ "$status" != "200" ]; then
    err "Lidarr unreachable at $LIDARR_URL (http $status)"
    ntfy "lidarr-sync FAIL" "Lidarr unreachable" high warning
    exit 1
fi

busy=$(curl -s -H "X-Api-Key: $KEY" "$LIDARR_URL/api/v1/command" | jq '[.[] | select(.status=="started")] | length')
if [ "${busy:-0}" -gt 0 ]; then
    log "Lidarr has $busy active commands — skipping"; exit 0
fi

log "=== sync run start ==="

# ----- Phase 1: enumerate beets -----
# Use tab separator from beets directly (titles can contain '|' — observed on
# Depeche Mode/"Speak & Spell | The 12\" Singles"). Tab is impossible in titles
# because beets' replace rule '[\x00-\x1f]': _ strips control chars including tab.
log "enumerating beets..."
docker exec -u "$BEETS_USER" "$BEETS_CONTAINER" beet ls -a -f \
    $'$id\t$albumartist\t$album\t$mb_albumid\t$mb_releasegroupid\t$path\t$albumtotal' \
    2>/dev/null > "$BEETS_RAW_TSV"

# Filter junk + Compilations/Soundtracks; emit norm key. Use ASCII unit-separator
# in norm key so it's never confused with an in-title pipe character.
#
# norm() must produce identical output for equivalent strings even when one
# side uses curly punctuation, accented characters, or an edition suffix and
# the other doesn't (incident 2026-04-24: 65% of Case-E rows were false
# positives from these mismatches; sync over-reported "Lidarr expects files
# not on disk").
awk -F'\t' -v OFS='\t' \
    -v music_root="$CONTAINER_MUSIC_ROOT" \
    -f "$SYNC_NORM_AWK" \
    -e 'NF >= 6 && $2 != "" && $3 != "" && $6 !~ "^" music_root "/(Compilations|Soundtracks)/" {
        print $1, $2, $3, $4, $5, $6, $7, norm($2) "\037" norm($3)
    }' "$BEETS_RAW_TSV" > "$BEETS_TSV"
b_total=$(wc -l < "$BEETS_TSV")
log "  beets albums (post-filter): $b_total"

# ----- Phase 2: enumerate Lidarr -----
log "enumerating Lidarr..."

# Artists: id\tname\tpath
curl -s -H "X-Api-Key: $KEY" "$LIDARR_URL/api/v1/artist" \
    | jq -r '.[] | [.id, .artistName, .path] | @tsv' \
    > "$LIDARR_ARTISTS_TSV"

# Albums (raw, no artist name lookup yet): id\tartistId\ttitle\tforeignAlbumId\tmonRelId\tmonRelTrackCount\ttrackFileCount\ttrackCount\tpath
curl -s -H "X-Api-Key: $KEY" "$LIDARR_URL/api/v1/album" \
    | jq -r '.[] | [
        .id, .artistId, .title,
        (.foreignAlbumId // ""),
        ([.releases[] | select(.monitored)] | first | .foreignReleaseId // ""),
        ([.releases[] | select(.monitored)] | first | .trackCount // 0),
        (.statistics.trackFileCount // 0),
        (.statistics.trackCount // 0),
        (.path // "")
    ] | @tsv' \
    > "$LIDARR_ALBUMS_RAW_TSV"

# Awk-join artists into albums; add norm key (must match the beets norm() exactly).
awk -F'\t' -v OFS='\t' \
    -f "$SYNC_NORM_AWK" \
    -e 'NR==FNR { name[$1] = $2; next }
    {
        aname = name[$2] != "" ? name[$2] : "?"
        n = norm(aname) "\037" norm($3)
        print $1, $2, aname, $3, $4, $5, $6, $7, $8, $9, n
    }' "$LIDARR_ARTISTS_TSV" "$LIDARR_ALBUMS_RAW_TSV" > "$LIDARR_ALBUMS_TSV"

l_albums=$(wc -l < "$LIDARR_ALBUMS_TSV")
l_artists=$(wc -l < "$LIDARR_ARTISTS_TSV")
log "  Lidarr artists: $l_artists, albums: $l_albums"

# ----- Phase 3: classify (single awk pipeline) -----
log "classifying..."

# Awk reads lidarr first (NR==FNR), builds three indexes:
#   by_rg[foreignAlbumId] = lidarr_record       — strongest (MBID exact)
#   by_norm[norm_key]     = lidarr_record       — fuzzy artist+album norm
#   by_alb[album_norm]    = lidarr_record       — album-only fallback (only
#                                                  used when alb_count[anorm]==1
#                                                  to avoid collisions like
#                                                  "Unleashed" by 3 artists).
# Then walks beets, classifies, marks lidarr rows that got matched.
# Then second-pass over lidarr finds Case E.
#
# Output columns: case<TAB>beets_id<TAB>artist<TAB>album<TAB>path<TAB>extra
#
# Lidarr cols (post-join): 1=lid 2=laid 3=laname 4=ltitle 5=lfaid 6=lmonrelid
#                          7=lmonreltracks 8=ltrackfile 9=ltrackcount 10=lpath 11=lnorm
# Beets cols:               1=bid 2=bartist 3=balbum 4=bmbalbum 5=bmbrg 6=bpath
#                          7=balbumtotal 8=bnorm

awk -F'\t' -v OFS='\t' '
function album_part(joined,    p) {
    split(joined, p, "\037")
    return p[2]
}
function artist_part(joined,    p) {
    split(joined, p, "\037")
    return p[1]
}
# Rough artist-similarity check: one side contains the other (substring) OR
# they share at least half of the shorter side length in common prefix.
# Prevents cross-artist collisions in album_only fallback like
# "Billie Eilish &burn" matching "Deep Purple Burn".
function artist_similar(a, b,    shorter, longer, plen) {
    if (a == "" || b == "") return 0
    if (index(a, b) > 0 || index(b, a) > 0) return 1
    shorter = (length(a) <= length(b)) ? a : b
    longer  = (length(a) <= length(b)) ? b : a
    plen = 0
    while (plen < length(shorter) && substr(shorter, plen+1, 1) == substr(longer, plen+1, 1)) plen++
    return (plen >= 4 && plen * 2 >= length(shorter)) ? 1 : 0
}
BEGIN {
    cA=0; cB=0; cC=0; cD=0; cE=0; cG=0
}
# Pass 1: ingest lidarr (FNR==NR while reading first file)
FNR==NR {
    n_lidarr++
    lid[FNR]=$1; laid[FNR]=$2; laname[FNR]=$3; ltitle[FNR]=$4; lfaid[FNR]=$5
    lmonrelid[FNR]=$6; lmonreltracks[FNR]=$7
    ltrackfile[FNR]=$8; ltrackcount[FNR]=$9; lpath[FNR]=$10; lnorm[FNR]=$11
    if ($5 != "" && $5 != "null") by_rg[$5]=FNR
    if ($11 != "" && $11 != "\037") {
        by_norm[$11]=FNR  # last-wins; tiebreak via norm_list siblings below
        # Track all Lidarr rows per norm key so we can mark Lidarr-side
        # duplicates (e.g. "Biophilia" + "Biophilia (Deluxe Edition)") as
        # matched together when beets matches any one of them.
        if ($11 in norm_list) norm_list[$11] = norm_list[$11] "," FNR
        else norm_list[$11] = FNR
    }
    anorm = album_part($11)
    if (anorm != "") {
        alb_count[anorm]++
        by_alb[anorm]=FNR  # last-wins; only used when count==1
    }
    next
}
# Pass 2: walk beets (FNR resets when 2nd file starts)
{
    bid=$1; bartist=$2; balbum=$3; bmbalbum=$4; bmbrg=$5; bpath=$6; balbumtotal=$7; bnorm=$8

    matched=0; via=""
    if (bmbrg != "" && bmbrg != "0" && (bmbrg in by_rg)) {
        matched = by_rg[bmbrg]; via="rg"
    } else if (bnorm in by_norm) {
        matched = by_norm[bnorm]; via="fuzzy"
    } else {
        # Album-only fallback: only when the Lidarr side has exactly one
        # album with this normalised title (avoids cross-artist collisions
        # like multiple "Unleashed" releases) AND the Lidarr artist name
        # is sufficiently similar to the beets artist name (prevents
        # "Billie Eilish &burn" matching "Deep Purple Burn" etc.).
        anorm = album_part(bnorm)
        if (anorm != "" && (anorm in by_alb) && alb_count[anorm] == 1) {
            cand = by_alb[anorm]
            if (artist_similar(artist_part(bnorm), artist_part(lnorm[cand]))) {
                matched = cand; via="album_only"
            }
        }
    }

    if (matched == 0) {
        # Case G: beets-only
        print "G", bid, bartist, balbum, bpath, "no_lidarr_match"
        cG++
        next
    }

    matched_lid[matched]=1
    # Also mark all Lidarr rows sharing the matched row norm key. Covers
    # Lidarr-side duplicates where the same logical album is registered
    # twice (e.g. standard edition + "(Deluxe Edition)" variant) — beets has
    # one entry, so the dup would otherwise fall into Case E.
    if (lnorm[matched] != "" && (lnorm[matched] in norm_list)) {
        split(norm_list[lnorm[matched]], _sib, ",")
        for (_j in _sib) matched_lid[_sib[_j]+0]=1
    }
    tf = ltrackfile[matched]+0
    tc = ltrackcount[matched]+0

    if ((via == "fuzzy" || via == "album_only") && (bmbrg == "" || bmbrg == "0")) {
        # Case D: low-confidence (no MBID, fuzzy or album-only match)
        printf "D\t%s\t%s\t%s\t%s\tlid=%s files=%d/%d (suggest: beet modify mb_albumid=...)\n",
            bid, bartist, balbum, bpath, lid[matched], tf, tc
        cD++
    } else if (tf == 0) {
        # Case C: lost-path
        printf "C\t%s\t%s\t%s\t%s\tlid=%s artistId=%s — needs RefreshArtist\n",
            bid, bartist, balbum, bpath, lid[matched], laid[matched]
        cC++
    } else if (tf != tc) {
        # Case B: partial
        printf "B\t%s\t%s\t%s\t%s\tlid=%s files=%d/%d\n",
            bid, bartist, balbum, bpath, lid[matched], tf, tc
        cB++
    } else {
        # Case A: clean
        printf "A\t%s\t%s\t%s\t%s\tlid=%s\n",
            bid, bartist, balbum, bpath, lid[matched]
        cA++
    }
}
END {
    # Pass 3: walk lidarr again for unmatched (Case E or filter F)
    for (i=1; i<=n_lidarr; i++) {
        if (i in matched_lid) continue
        if (ltrackfile[i]+0 > 0) {
            printf "E\t-\t%s\t%s\t%s\tlid=%s files=%d/%d (Lidarr expects files not on disk)\n",
                laname[i], ltitle[i], lpath[i], lid[i], ltrackfile[i], ltrackcount[i]
            cE++
        }
        # Case F (no files, monitored) → filtered out per design
    }
    # Send counts to stderr so the bash caller can capture them
    printf "COUNTS\tA=%d\tB=%d\tC=%d\tD=%d\tE=%d\tG=%d\n", cA, cB, cC, cD, cE, cG | "cat 1>&2"
}
' "$LIDARR_ALBUMS_TSV" "$BEETS_TSV" > "$REPORT_TSV" 2> "$SYNC_COUNTS_TMP"

# Parse counts
counts=$(cat "$SYNC_COUNTS_TMP")
A=$(echo "$counts" | awk -F'[\t=]' '/^COUNTS/{print $3}')
B=$(echo "$counts" | awk -F'[\t=]' '/^COUNTS/{print $5}')
C=$(echo "$counts" | awk -F'[\t=]' '/^COUNTS/{print $7}')
D=$(echo "$counts" | awk -F'[\t=]' '/^COUNTS/{print $9}')
E=$(echo "$counts" | awk -F'[\t=]' '/^COUNTS/{print $11}')
G=$(echo "$counts" | awk -F'[\t=]' '/^COUNTS/{print $13}')

log "results: A=$A  B=$B  C=$C  D=$D  E=$E  G=$G"
log "report: $REPORT_TSV"

if [ "${E:-0}" -gt 0 ]; then
    log "CRITICAL: $E Case-E rows (Lidarr expects files not on disk per beets) — top 10:"
    grep -P '^E\t' "$REPORT_TSV" | head -10 | awk -F'\t' '{print "  E: " $3 " / " $4}' >> "$LOG"
fi

# ntfy summary
prio="default"; tags="musical_note"
[ "${E:-0}" -gt 0 ] && { prio="high"; tags="warning,musical_note"; }
ntfy "lidarr-sync $(date +%F)" \
    "$(printf '✓ %s clean (A)\n⚠ %s partial (B)\n⚠ %s lost-path (C)\n⚠ %s no-MBID (D)\n🔥 %s Lidarr-only (E)\n⚠ %s beets-only (G)\nlog: %s' "$A" "$B" "$C" "$D" "$E" "$G" "$LOG")" \
    "$prio" "$tags"

log "=== sync run end ==="
