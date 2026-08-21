# Tag-first library realignment

Date: 2026-08-20
Status: accepted

## Context

Folder names and beets tags can drift apart. When they do, `beet move` is the
obvious tool, but it resolves the conflict in one direction only: it rewrites
**folders to match tags**. That is the wrong direction when the tags are the
side that is wrong.

A large drift was traced to tags having been title-cased at some point in the
past (`In The Meantime`, `Save Rock And Roll`, `Will Of The People`) while the
folders on disk had kept the original MusicBrainz capitalization
(`In the Meantime`, `Save Rock and Roll`, `Will of the People`). Running
`beet move` would have propagated the wrong names onto thousands of folders.

The rule that came out of this: **correct the tags from MusicBrainz first, then
let `beet move` align folders.** Folders are frequently the better record of
truth, so never let a move run before the tags have been re-derived.

## Why not `mbsync`

`mbsync` looks like the right tool and is not, unless the library was imported
with full MusicBrainz matches.

- `mbsync` requires `mb_albumid` (a **release** ID). Linking albums for
  Lidarr reconciliation produces `mb_releasegroupid` (a **release-group** ID).
  These are different identifiers and the release-group ID does not satisfy
  `mbsync`.
- Even with `mb_albumid` set, `mbsync` builds its track mapping from
  `mb_releasetrackid` / `mb_trackid` **on each item**, then applies metadata
  only to items in that mapping. Items with no track-level MBIDs produce an
  empty mapping, and `mbsync` exits via `if not changed: continue` having
  changed nothing. It does this silently: verbose logging still prints
  `applying changes to <album>`.

Track-level MBIDs only come from an actual autotagger match. So for a library
imported without matches, `mbsync` cannot help and `beet import -L` is the
only path.

Resolving release-group IDs into release IDs (query the RG, keep releases whose
total track count equals the local track count) is possible and cheap, but it
does **not** unlock `mbsync`, because it does not create track-level MBIDs.
Note also that a track-count match is usually not unique: most release groups
contain several releases sharing one tracklist.

## Decision

Use `beet import -L` (library retag) in small batches, and commit only the
albums that a sandbox run proves safe.

### The sandbox pattern

`beet import -L` cannot preview a match from the CLI — `-p` is `--resume`, and
`--pretend` only lists files. To get a real preview, run the import against a
**copy of the database**:

```bash
cp musiclibrary.blb _sim.blb
beet -l /config/_sim.blb import -L -q -W -M <query>
```

`-W` (no tag writes) and `-M` (no moves) mean nothing outside the copied DB is
touched. Diffing the copy against the real database then answers, per album:
whether the match applied, what the new folder would be, and how many files
would be renamed. Only the albums that come out folder-aligned need to be
committed blind; the rest can be reviewed as a list.

### Batch loop

1. List misaligned albums (album whose first item's directory differs from its
   computed `destination()`).
2. Take a batch; run the sandbox import; classify into applied / skipped /
   would-rename.
3. Commit the safe subset with a real `beet import -L -q -M`.
4. Review the renames, then `beet move -a` the approved ones.
5. Refresh the downstream media manager and verify its file count.

Back up the beets database before every write step.

## Consequences

- **Album IDs are not stable.** `import -L` deletes and recreates album rows,
  so every id list must be rebuilt after each batch. Verify total album and
  item counts are unchanged to prove nothing was orphaned.
- **Matching is not deterministic.** The same album and query can apply in one
  run and be skipped in the next, and equally-scored releases break ties
  differently. Treat a sandbox result as a forecast, not a contract.
- **Quiet mode skips weak matches.** `-q` skips anything below a `strong`
  recommendation, silently. Count and report skips; do not assume a batch of
  N produced N results.
- **Run imports with a trimmed plugin set.** A full import fires every enabled
  plugin (lyrics, art, genre, fingerprinting), which is slow and does unrelated
  network work. Pass `--config` with a minimal `plugins:` list.
- Albums absent from MusicBrainz (self-released, bootlegs) will never resolve.
  Exclude them permanently rather than retrying them in every batch.

## Artist-directory hazard

A rename that changes the **artist** directory is categorically riskier than
one that changes only the album directory, because it can split one artist
across two folders. Before moving, compare the parent directory of the source
and destination, and hold anything where they differ for review.

Two cases look identical and are opposite:

- The match introduces a compound artist (`X feat. Y`, `X & Y`) that has no
  existing folder. This **splits** an artist and should be rejected.
- The match moves an album to an artist folder that **already exists** (for
  example a native-script name alongside a romanized one). This **merges** a
  split that was already there and is worth doing.

Check whether the destination artist folder exists before deciding.

## Downstream media manager notes

- A media manager re-matches files by tags. Renaming a folder for an album
  whose tags were **not** updated is the dangerous combination: the manager
  drops the old paths and may then refuse the new ones. Prefer not to move
  folders for albums the importer skipped.
- Lidarr rejects re-import below a match threshold with
  `Album match is not close enough: NN % vs 80 %`. Its own `/manualimport`
  endpoint will still propose the correct album and track IDs; POSTing those
  back as a `ManualImport` command bypasses the threshold.
- Never trust a file count taken while the manager has a command queued or
  running. A scheduled rescan in flight reports a partially rebuilt index,
  which reads as data loss and is not. Check the command queue is empty first.
- When a folder rename changes an artist path, update the artist record with
  `moveFiles=false` before rescanning, or the manager will look for files at a
  path that no longer exists.

## Verification per batch

- beets album and item totals unchanged.
- Zero items whose recorded path does not exist on disk.
- Misaligned count decreased by the expected amount.
- Downstream file count unchanged (measured with an empty command queue).
