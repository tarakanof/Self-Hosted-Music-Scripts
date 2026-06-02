#!/bin/bash
# Shared runtime configuration for the music pipeline scripts.
#
# Tracked deployment defaults live in config/music-pipeline.env. Put
# machine-local overrides in config/music-pipeline.local, or point
# MUSIC_PIPELINE_CONFIG / MUSIC_PIPELINE_LOCAL_CONFIG at other env files.

CONFIG_LIB_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPT_ROOT="$(cd -- "$CONFIG_LIB_DIR/.." && pwd -P)"

CONFIG_FILE="${MUSIC_PIPELINE_CONFIG:-$SCRIPT_ROOT/config/music-pipeline.env}"
if [ -r "$CONFIG_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$CONFIG_FILE"
    set +a
fi

LOCAL_CONFIG_FILE="${MUSIC_PIPELINE_LOCAL_CONFIG:-$SCRIPT_ROOT/config/music-pipeline.local}"
if [ -r "$LOCAL_CONFIG_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$LOCAL_CONFIG_FILE"
    set +a
fi

: "${MUSIC_PIPELINE_LOCALE:=en_US.UTF-8}"
# Force the locale rather than defaulting it. gawk's multibyte regex (lib/
# sync-norm.awk) and Cyrillic/accented tolower() only work under a UTF-8 locale;
# cron runs with no LANG/LC_ALL (defaults to C) and an inherited LC_ALL=C would
# silently reintroduce byte-mode false positives. Override the target locale via
# MUSIC_PIPELINE_LOCALE if a different UTF-8 locale is installed.
export LC_ALL="$MUSIC_PIPELINE_LOCALE"

: "${APP_ROOT:=$SCRIPT_ROOT}"
: "${TMP_DIR:=/tmp}"

: "${HOST_TORRENTS_ROOT:=/mnt/user/Torrents}"
: "${HOST_COMPLETE:=$HOST_TORRENTS_ROOT/complete}"
: "${REVIEW_DIR:=$HOST_TORRENTS_ROOT/review}"
: "${HOST_MEDIA_ROOT:=/mnt/user/Media}"
: "${MEDIA_DIR:=$HOST_MEDIA_ROOT}"
: "${MUSIC_HOST:=$HOST_MEDIA_ROOT/Music}"
: "${MUSIC_ROOT:=$MUSIC_HOST}"

: "${CONTAINER_DOWNLOADS_ROOT:=/downloads}"
: "${CONTAINER_MUSIC_ROOT:=/music}"
: "${MUSIC_CONT:=$CONTAINER_MUSIC_ROOT}"

: "${BEETS_CONTAINER:=beets}"
: "${BEETS_USER:=abc}"
: "${TRANSMISSION_CONTAINER:=transmission}"
: "${TRANSMISSION_RPC_HOST:=localhost}"
: "${TRANSMISSION_RPC_USER:=transmission}"
: "${TRANSMISSION_PASSWORD_ENV:=PASS}"
: "${TRANSMISSION_RPC_PASSWORD_FILE:=}"
: "${TRANSMISSION_RPC_PASSWORD:=}"

: "${LIDARR_URL:=http://localhost:8686}"
: "${LIDARR_KEY_FILE:=$APP_ROOT/.lidarr-api-key}"

: "${NTFY_BASE_URL:=http://localhost:2586}"
: "${NTFY_TOPIC:=music-pipeline}"
: "${NTFY_URL:=$NTFY_BASE_URL/$NTFY_TOPIC}"
: "${NTFY_TOKEN_FILE:=$APP_ROOT/.ntfy-token}"

: "${LOG_DIR:=$APP_ROOT}"
: "${PIPELINE_LOG:=$LOG_DIR/music-pipeline.log}"
: "${REPROCESS_LOG:=$LOG_DIR/music-reprocess.log}"
: "${LIDARR_SYNC_LOG:=$LOG_DIR/music-lidarr-sync.log}"
: "${HEALTH_CHECK_LOG:=$LOG_DIR/music-health-check.log}"
: "${LYRICS_SWEEP_LOG:=$LOG_DIR/music-lyrics-sweep.log}"

: "${PIPELINE_LOCKFILE:=$TMP_DIR/music-pipeline.lock}"
: "${REPROCESS_LOCKFILE:=$TMP_DIR/music-reprocess.lock}"
: "${LIDARR_SYNC_LOCKFILE:=$TMP_DIR/music-lidarr-sync.lock}"
: "${HEALTH_CHECK_LOCKFILE:=$TMP_DIR/music-health-check.lock}"
: "${LYRICS_SWEEP_LOCKFILE:=$TMP_DIR/music-lyrics-sweep.lock}"

: "${LIDARR_SYNC_REPORT_TSV:=$TMP_DIR/music-lidarr-sync-report.tsv}"
: "${BEETS_RAW_TSV:=$TMP_DIR/beets-raw.tsv}"
: "${BEETS_TSV:=$TMP_DIR/beets-albums.tsv}"
: "${LIDARR_ARTISTS_TSV:=$TMP_DIR/lidarr-artists.tsv}"
: "${LIDARR_ALBUMS_RAW_TSV:=$TMP_DIR/lidarr-albums-raw.tsv}"
: "${LIDARR_ALBUMS_TSV:=$TMP_DIR/lidarr-albums.tsv}"
: "${SYNC_COUNTS_TMP:=$TMP_DIR/sync-counts.tmp}"

: "${HEALTH_REPORT:=$TMP_DIR/music-health-check-report.tsv}"
: "${HEALTH_REPORT_DUPS:=$TMP_DIR/music-health-dups.tsv}"
: "${HEALTH_REPORT_ARTIST_DUPS:=$TMP_DIR/music-health-artist-dups.tsv}"
: "${HEALTH_REPORT_BROKEN:=$TMP_DIR/music-health-broken.tsv}"
: "${HEALTH_REPORT_ORPHANS:=$TMP_DIR/music-health-orphans.tsv}"
: "${HEALTH_REPORT_PARTIAL:=$TMP_DIR/music-health-partial.tsv}"
: "${HEALTH_FS_TSV:=$TMP_DIR/music-health-fs.tsv}"
: "${HEALTH_BEETS_TSV:=$TMP_DIR/music-health-beets.tsv}"
: "${HEALTH_BEETS_PATHS_TSV:=$TMP_DIR/music-health-beets-paths.tsv}"
: "${HEALTH_FS_PATHS_TSV:=$TMP_DIR/music-health-fs-paths.tsv}"
: "${HEALTH_TRACK_COUNTS_TSV:=$TMP_DIR/music-health-track-counts.tsv}"
: "${HEALTH_PREV_DUPS:=$TMP_DIR/music-health-prev-dups.tsv}"
: "${HEALTH_PREV_ARTIST_DUPS:=$TMP_DIR/music-health-prev-artist-dups.tsv}"
: "${HEALTH_PREV_BROKEN:=$TMP_DIR/music-health-prev-broken.tsv}"
: "${HEALTH_PREV_ORPHANS:=$TMP_DIR/music-health-prev-orphans.tsv}"
: "${HEALTH_PREV_PARTIAL:=$TMP_DIR/music-health-prev-partial.tsv}"

: "${BACKUP_ROOT:=$APP_ROOT/reprocess-backups}"
: "${BACKUP_RETENTION_DAYS:=30}"
: "${BEETS_IMPORT_TIMEOUT:=1800}"
: "${SYNC_NORM_AWK:=$APP_ROOT/lib/sync-norm.awk}"

# NOTE: `${VAR:=...}` defaults must not contain `{n}` interval quantifiers — the
# closing `}` terminates the parameter expansion early (verified bash 3.2–5.3),
# truncating the value. Use `[0-9][0-9]` for "exactly two digits" instead.
: "${MUSIC_RE:=\.(flac|mp3|m4a|ogg|wav|ape|wv|aac|opus|wma)$}"
: "${VIDEO_RE:=\.(mkv|mp4|avi|wmv|mov|ts|m4v|webm)$}"
: "${SKIP_LOCATION_PATTERNS:=*/tv-sonarr*|*/radarr*|*/books*}"
: "${VIDEO_SERIES_RE:=s[0-9][0-9]e[0-9][0-9]|season[ ._-]*[0-9]|episode|\.s[0-9][0-9]\.|complete\.series}"
: "${VIDEO_ANIME_RE:=anilibria|subsplease|anime|\.dxd|fairy.tail|spy.x.family|\[horriblesubs\]}"

host_to_container_downloads_path() {
    local path="$1"
    printf '%s\n' "${path/#$HOST_COMPLETE/$CONTAINER_DOWNLOADS_ROOT}"
}

container_downloads_to_host_path() {
    local path="$1"
    printf '%s\n' "${path/#$CONTAINER_DOWNLOADS_ROOT/$HOST_TORRENTS_ROOT}"
}

host_to_container_music_path() {
    local path="$1"
    printf '%s\n' "${path/#$MUSIC_HOST/$CONTAINER_MUSIC_ROOT}"
}

container_music_to_host_path() {
    local path="$1"
    printf '%s\n' "${path/#$CONTAINER_MUSIC_ROOT/$MUSIC_HOST}"
}

should_skip_download_location() {
    local location="$1" pattern result=1
    local old_ifs="$IFS" restore_glob=0
    # Disable pathname expansion around the split so the glob patterns in
    # $SKIP_LOCATION_PATTERNS are word-split on '|' but NOT expanded against the
    # filesystem (which would drop a pattern if the CWD happened to contain a
    # matching path). `set -f` does not affect the `case` glob matching below.
    case $- in *f*) ;; *) set -f; restore_glob=1 ;; esac
    IFS='|'
    for pattern in $SKIP_LOCATION_PATTERNS; do
        case "$location" in
            $pattern) result=0; break ;;
        esac
    done
    IFS="$old_ifs"
    [ "$restore_glob" -eq 1 ] && set +f
    return "$result"
}
