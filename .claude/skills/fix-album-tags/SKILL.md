---
name: fix-album-tags
description: Reconcile one album's tags, beets DB entry, folder path, and MusicBrainz identity. Use when a user reports wrong album metadata, casing, year, path, or MusicBrainz IDs for a specific album.
---

Purpose: bring one album's file tags, beets database row, and folder path back
into agreement. Use the configured paths and container values from
`config/music-pipeline.env`.

## Inputs

Ask for or infer:

- Artist and album.
- Host path or beets album id if known.
- Desired MusicBrainz release ID if the match is ambiguous.

## Discovery

Before running shell snippets, load the repository config so variables such as
`MUSIC_HOST`, `CONTAINER_MUSIC_ROOT`, `BEETS_CONTAINER`, and `BEETS_USER` are
defined:

```bash
. ./lib/config.sh
```

Then use configured values:

```bash
find "$MUSIC_HOST" -mindepth 2 -maxdepth 3 -type d -iname "*<hint>*"
docker exec -u "$BEETS_USER" "$BEETS_CONTAINER" \
  beet ls -a -f '$id | $albumartist | $album | path=$path' <fragment>
```

If a path is on the host, map it to the container music path using the same
relationship configured by `MUSIC_HOST` and `CONTAINER_MUSIC_ROOT`.

## Preflight

Before modifying anything:

1. Identify the beets album id.
2. Verify the displayed beets `$path` points at real files.
3. Inspect current tags from at least one audio file.
4. Check whether the intended MusicBrainz release is unambiguous.
5. Back up before any filesystem move or broad retag.

Useful checks:

```bash
docker exec -u "$BEETS_USER" "$BEETS_CONTAINER" \
  beet ls -a -f '$id | $albumartist | $album | year=$year original_year=$original_year | path=$path | mb_albumid=$mb_albumid' id:<N>

docker exec -u "$BEETS_USER" "$BEETS_CONTAINER" \
  ffprobe -v error -show_entries format_tags -of default=nw=1 "<container-audio-path>"
```

## Fix Pattern

Prefer beets-native changes over manual path moves:

```bash
docker exec -u "$BEETS_USER" "$BEETS_CONTAINER" \
  beet modify -a -y id:<N> albumartist='<Artist>' album='<Album>' original_year=<YYYY>

docker exec -u "$BEETS_USER" "$BEETS_CONTAINER" \
  beet move -a id:<N>
```

If the album must be force-matched to a MusicBrainz release, use an explicit
release ID:

```bash
docker exec -u "$BEETS_USER" "$BEETS_CONTAINER" \
  beet remove -a -f id:<old_id>

docker exec -u "$BEETS_USER" "$BEETS_CONTAINER" \
  beet import -I --search-id=<MBID> "<container-album-path>"
```

Avoid `-q` when you need to answer a prompt. If beets prompts for confirmation,
feed the expected command explicitly; do not pipe a blind `yes`.

## Verify

After changes:

```bash
docker exec -u "$BEETS_USER" "$BEETS_CONTAINER" \
  beet ls -a -f '$albumartist | $album | path=$path' id:<N>

docker exec -u "$BEETS_USER" "$BEETS_CONTAINER" \
  beet ls -f '$disc|$track|$title' album_id:<N> | head
```

Confirm:

- Files exist at the displayed beets path.
- Folder path matches the configured beets path template.
- Album id count is as expected.
- There are no empty duplicate folders left behind.

## Stop Conditions

Ask before acting if:

- Multiple plausible MusicBrainz releases exist.
- The operation would delete files.
- The fix needs disk-level cleanup outside `MUSIC_HOST`.
- The match count is not exactly what was expected.
