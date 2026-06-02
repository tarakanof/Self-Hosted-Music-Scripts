# AGENTS.md

Instructions for AI coding agents working in this repository.

`CLAUDE.md` is a symlink to this file so Claude Code can load the same project
memory.

## Project Shape

This repo is a configurable Bash-based music pipeline for self-hosted media
servers. The runtime stack is:

- Transmission downloads files.
- beets imports, converts, tags, and moves music.
- Lidarr handles discovery and monitoring.
- ntfy sends optional notifications.

The scripts must stay usable from a public clone. Non-secret deployment
defaults may live in `config/music-pipeline.env`; do not add host-specific
values anywhere else, and never commit tokens, passwords, one-off production
state, logs, or generated reports.

## Configuration Rules

Runtime defaults belong in tracked config files:

- `config/music-pipeline.env`
- `config/music-pipeline.env.example`
- `config/beets-config.yaml.example`
- `config/beets-backfill.yaml.example`

`config/music-pipeline.env` may include non-secret deployment defaults such as
paths, container names, local usernames, and private-network URLs. Actual
secrets must remain in untracked files.

Machine-specific overrides belong in ignored files:

- `config/music-pipeline.local`
- `config/*.local`
- `config/**/*.local`

All Bash entrypoints source `lib/config.sh`. When adding a setting:

1. Add a safe default to `lib/config.sh`.
2. Add a documented value to `config/music-pipeline.env.example`.
3. If it is a non-secret default for this repo, add it to
   `config/music-pipeline.env`.
4. If it is machine-specific or sensitive-by-context, put it in
   `config/music-pipeline.local`.
5. Do not hardcode runtime values in scripts, docs, hooks, or skills.

Secrets should be read from files such as `.lidarr-api-key` and `.ntfy-token`.
Never commit secret files, logs, backups, local permission files, or generated
library reports.

## Local Operator Notes

For this local checkout, the original private runbook and historical analysis
were preserved under ignored files:

- `private/original/AGENTS.md`
- `private/original/README.md`
- `private/original/docs/`

When doing production maintenance, beets album repair, or library cleanup in
this checkout, read `private/original/AGENTS.md` first if it exists. It contains
site-specific lessons that are intentionally not part of the public tracked
docs.

## Scripts

- `music-pipeline.sh`: main importer for completed Transmission downloads.
- `music-reprocess.sh`: manual library maintenance for FLAC/mixed-format
  folders.
- `music-lidarr-sync.sh`: read-only beets/Lidarr reconciliation.
- `music-health-check.sh`: read-only filesystem/beets consistency audit.
- `music-lyrics-sweep.sh`: optional lyrics backfill.
- `music-cue-split.sh`: CUE+image splitter.

Keep scripts Bash-first. Use existing helper functions from `lib/config.sh`
for host/container path conversion.

## Safety Rules

- Prefer read-only discovery before edits.
- Run `bash -n` on changed shell scripts.
- Keep destructive changes narrowly scoped.
- Do not use broad `rm -rf` or source-removing rsync commands against media
  library roots.
- Do not run unscoped `beet update`, `beet remove`, or bulk `beet modify`.
- Preserve backups and ignored local files.

For beets album modifications, list matches first, verify counts, then act on a
specific `id:N` or similarly narrow query.

## Known Traps For Reviewers

These are the high-risk patterns that hooks, skills, and reviewers should keep
checking for:

- **Unscoped beets updates:** do not run `beet update` without a narrow query.
  Even scoped updates can remove DB entries whose recorded paths are missing.
- **Album-side `album_id:N`:** when using `beet -a`, prefer album `id:N`.
  `album_id:N` is a track-side concept and can match unexpectedly in album
  context.
- **Source-removing rsync:** avoid `rsync --remove-source-files` against media
  library roots, especially Unraid user shares.
- **Manual pre-move before `beet modify`:** do not move files by hand and then
  ask beets to modify path-template fields. Prefer beets-native `modify` plus
  `move` while the DB path still points at real files.
- **Missing `original_year`:** beets path templates can drop the year suffix
  when `original_year` is unset or zero. Set it before path-template moves when
  the folder convention expects years.
- **Blind `yes`:** if beets prompts, feed the expected answer explicitly. A
  generic `yes` can loop on prompts that do not accept lowercase `y`.

## Public Readiness

This repo should read as reusable software, not as a private server journal.

Avoid adding outside the documented config files:

- Internal IP addresses or hostnames.
- Real usernames that are not necessary for examples.
- Personal library inventories, album gap reports, or one-off TSV snapshots.
- Absolute install paths outside examples.
- Current production counts that will age immediately.

When a production lesson is worth preserving, generalize it into a safety note
or a test. Do not preserve personal incident details unless they are required
to understand the code.

## Verification

After script edits, run:

```bash
bash -n lib/config.sh \
  music-pipeline.sh \
  music-reprocess.sh \
  music-lidarr-sync.sh \
  music-health-check.sh \
  music-lyrics-sweep.sh \
  music-cue-split.sh
```

Also check local overrides remain ignored:

```bash
git status --short --ignored -- config/music-pipeline.local private
```

Expected output may include:

```text
!! config/music-pipeline.local
!! private/
```
