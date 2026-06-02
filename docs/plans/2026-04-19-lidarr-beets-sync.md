# Lidarr and beets reconciliation sync

**Date:** 2026-04-19
**Status:** Phase 1 read-only audit

## Goal

Compare Lidarr's view of the music library with beets' authoritative database.
Surface drift before it causes redundant downloads or misleading monitoring
state.

## Non-goals

- Replace Lidarr discovery/search/RSS.
- Modify beets data automatically.
- Import files.
- Delete or move media.

## Inputs

The script reads:

- Lidarr API data from `LIDARR_URL` with the key in `LIDARR_KEY_FILE`.
- beets album data through `docker exec` against `BEETS_CONTAINER`.
- Normalization rules from `SYNC_NORM_AWK`.

All paths and container names come from `lib/config.sh` and
`config/music-pipeline.env`.

## Match Strategy

1. Prefer release-group MBID when available.
2. Fall back to normalized artist + album title.
3. Use album-only fallback only when the Lidarr side is unambiguous and artist
   names are similar.
4. Skip compilation and soundtrack namespaces by default.

## Cases

| Case | Meaning | Action |
|---|---|---|
| A | beets and Lidarr agree, full file count | clean |
| B | Lidarr sees some files but not all | warn partial |
| C | Lidarr album has zero files for a beets match | needs refresh/rescan |
| D | fuzzy match without MBID confidence | warn low confidence |
| E | Lidarr claims files for an album not matched in beets | critical warning |
| G | beets album has no Lidarr match | warn beets-only |

Case F (Lidarr monitored but no files) is normal wishlist behavior and is not
reported.

## Outputs

- Append-only sync log, configured by `LIDARR_SYNC_LOG`.
- Current-run TSV report, configured by `LIDARR_SYNC_REPORT_TSV`.
- Optional ntfy summary.

## Safety

Phase 1 is read-only. It performs Lidarr GET requests and beets list commands.
It does not write to Lidarr, beets, or the filesystem.

Future write phases should be feature-flagged and should keep read-only mode as
the default.
