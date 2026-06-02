---
name: consolidate-album-pair
description: Resolve two folders that appear to represent the same logical album. Use when a health-check report or user request identifies duplicate, split, or partially overlapping album folders.
---

Purpose: classify a pair of album folders and apply the least destructive
workflow. Use configured values from `config/music-pipeline.env`, especially
`MUSIC_HOST`, `CONTAINER_MUSIC_ROOT`, `BEETS_CONTAINER`, `BEETS_USER`, and
`BACKUP_ROOT`.

## Inputs

Require two paths or enough artist/album context to find two candidate folders.

## Preflight

Before running shell snippets, load the repository config so variables such as
`MUSIC_HOST`, `CONTAINER_MUSIC_ROOT`, `BEETS_CONTAINER`, `BEETS_USER`, and
`BACKUP_ROOT` are defined:

```bash
. ./lib/config.sh
```

1. Confirm both paths are inside the configured music library.
2. Count audio files on both sides.
3. Query beets for DB coverage.
4. Identify whether each folder contains the same edition, separate discs, a
   different edition, or stale non-audio leftovers.
5. Create a tar backup before moving or deleting files.

Example checks:

```bash
find "<host-path-A>" "<host-path-B>" -type f | sort

docker exec -u "$BEETS_USER" "$BEETS_CONTAINER" \
  beet ls -a -f '$id | $albumartist | $album | $path' '<artist-or-album-fragment>'
```

## Classification

Use these buckets:

- Empty shell: one path has no audio.
- Identical duplicate: same tracks and same edition in both folders.
- Split album: folders contain different discs or track ranges of one release.
- Different edition: folders are related but should remain separate albums.
- Partial plus extras: one folder is incomplete or contains only artwork/logs.

Do not collapse different editions just because names are similar.

## Safe Workflow

For changes that only affect beets path-template fields, prefer beets-native
moves:

```bash
docker exec -u "$BEETS_USER" "$BEETS_CONTAINER" \
  beet modify -a -y id:<N> original_year=<YYYY>

docker exec -u "$BEETS_USER" "$BEETS_CONTAINER" \
  beet move -a id:<N>
```

For true split albums, consolidate files into one backed-up folder, remove only
the stale beets entry, and import the consolidated folder with an explicit
MusicBrainz release when possible:

```bash
docker exec -u "$BEETS_USER" "$BEETS_CONTAINER" \
  beet remove -a -f id:<old_id>

docker exec -u "$BEETS_USER" "$BEETS_CONTAINER" \
  beet import -I --search-id=<MBID> "<container-album-path>"
```

## Verify

After consolidation:

```bash
docker exec -u "$BEETS_USER" "$BEETS_CONTAINER" \
  beet ls -a -f '$id | $album | $albumtotal | $path' '<album-fragment>'

docker exec -u "$BEETS_USER" "$BEETS_CONTAINER" \
  beet ls -f '$disc|$track|$title' album_id:<N> | sort

./music-health-check.sh
```

Confirm:

- Expected beets DB entry count.
- Expected track count and disc layout.
- No audio-bearing orphan folder remains.
- Backup exists until the user confirms cleanup.

## Stop Conditions

Ask before acting if:

- The two folders look like different editions.
- MusicBrainz candidates are ambiguous.
- A command would delete audio files.
- A move would leave the configured music library root.
- The preflight match count differs from expectations.
