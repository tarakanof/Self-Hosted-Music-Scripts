# Self-hosted Music Pipeline

Bash automation for a self-hosted music stack where Transmission downloads
music, beets imports and enriches the library, Lidarr handles discovery, and
ntfy sends notifications.

The default configuration targets the original Unraid plus Docker setup, but
runtime settings live in env files so the scripts can be adapted to another
host layout.

## What It Does

- Watches Transmission for torrents in a completed or ready state.
- Skips downloads owned by Sonarr/Radarr or other configured drop zones.
- Classifies downloads as music or video.
- Converts FLAC to ALAC before import.
- Imports music through beets with MusicBrainz tagging and cover art.
- Moves unmatched music to a review folder.
- Moves video files into Movies, Series, or Anime folders.
- Notifies ntfy for imports, duplicates, review items, failures, and summaries.
- Reconciles beets, Lidarr, and the filesystem with read-only audit scripts.

## Scripts

| Script | Purpose |
|---|---|
| `music-pipeline.sh` | Main importer. Processes completed Transmission items. |
| `music-reprocess.sh` | Manual cleanup for existing FLAC/mixed-format library folders. |
| `music-lidarr-sync.sh` | Read-only beets/Lidarr reconciliation report. |
| `music-health-check.sh` | Read-only filesystem/beets health report. |
| `music-lyrics-sweep.sh` | Optional one-shot lyrics backfill. |
| `music-cue-split.sh` | Splits CUE+image albums into per-track FLAC files. |

## Requirements

- Bash
- Docker
- Transmission with `transmission-remote`
- beets container with `beet`, `ffmpeg`, and `ffprobe`
- Lidarr
- `curl`, `jq`, `awk`/`gawk`, `find`, `flock`, `timeout`
- Optional: ntfy for notifications

The examples assume these container names:

- `beets`
- `transmission`

Both can be changed in `config/music-pipeline.env`.

## Configuration

Runtime configuration is loaded from the tracked default file:

```bash
config/music-pipeline.env
```

That file contains only paths, service URLs, container names, and usernames.
Secrets are still read from separate untracked files. A sanitized template is
also available:

```bash
config/music-pipeline.env.example
```

For machine-local overrides without editing the tracked default, create the
ignored file:

```bash
config/music-pipeline.local
```

It is loaded after `config/music-pipeline.env`, so values there override the
tracked defaults.

The important settings are:

| Variable | Meaning |
|---|---|
| `HOST_TORRENTS_ROOT` | Host path that maps to Transmission downloads. |
| `HOST_COMPLETE` | Host path for completed downloads. |
| `REVIEW_DIR` | Host folder for music that needs manual review. |
| `HOST_MEDIA_ROOT` | Host media root containing `Music`, `Movies`, `Series`, `Anime`. |
| `MUSIC_HOST` | Host music library path. |
| `CONTAINER_DOWNLOADS_ROOT` | Path to completed downloads inside the beets container. |
| `CONTAINER_MUSIC_ROOT` | Path to the music library inside beets and Lidarr. |
| `BEETS_CONTAINER` / `BEETS_USER` | beets Docker container name and user. |
| `TRANSMISSION_CONTAINER` | Transmission Docker container name. |
| `TRANSMISSION_RPC_USER` | Transmission RPC username. |
| `TRANSMISSION_PASSWORD_ENV` | Container env var holding the Transmission password. |
| `LIDARR_URL` | Lidarr base URL. |
| `LIDARR_KEY_FILE` | File containing the Lidarr API key. |
| `NTFY_BASE_URL`, `NTFY_TOPIC`, `NTFY_TOKEN_FILE` | ntfy notification settings. |

You can also run with a different config file:

```bash
MUSIC_PIPELINE_CONFIG=/path/to/music-pipeline.env ./music-pipeline.sh
```

Secrets should be stored in separate files, not committed:

```bash
printf '%s\n' '<lidarr-api-key>' > .lidarr-api-key
printf '%s\n' '<ntfy-token>' > .ntfy-token
chmod 600 .lidarr-api-key .ntfy-token
```

## Beets Config

Example beets configs are tracked under `config/`:

- `config/beets-config.yaml.example`
- `config/beets-backfill.yaml.example`

The importer expects beets to move files from the downloads mount into the
music mount, and it expects the displayed beets paths to live under
`CONTAINER_MUSIC_ROOT` (default `/music`).

## Running

Main importer:

```bash
./music-pipeline.sh
DRY_RUN=1 ./music-pipeline.sh
```

Reprocess existing library folders:

```bash
./music-reprocess.sh --help
./music-reprocess.sh --phase a --dry-run
./music-reprocess.sh --phase b --limit 5
```

Read-only audits:

```bash
./music-lidarr-sync.sh
./music-health-check.sh
```

Lyrics sweep:

```bash
nohup ./music-lyrics-sweep.sh </dev/null >/dev/null 2>&1 &
```

CUE splitter:

```bash
./music-cue-split.sh "$HOST_COMPLETE/<album-dir>"
./music-cue-split.sh --dry-run "$HOST_COMPLETE/<album-dir>"
```

## Scheduling On Unraid

Install the repo somewhere persistent, for example:

```bash
/mnt/user/appdata/scripts
```

Then create cron entries via Unraid User Scripts or your preferred cron
mechanism. Example schedules:

```cron
0 * * * * /mnt/user/appdata/scripts/music-pipeline.sh >/dev/null 2>&1
0 4 * * * /mnt/user/appdata/scripts/music-lidarr-sync.sh >/dev/null 2>&1
30 4 * * 0 /mnt/user/appdata/scripts/music-health-check.sh >/dev/null 2>&1
```

## Safety Notes

- Keep `.lidarr-api-key`, `.ntfy-token`, `config/music-pipeline.local`, logs,
  backups, and `private/` out of Git.
- Run `DRY_RUN=1 ./music-pipeline.sh` before the first real importer run.
- Disable Lidarr Completed Download Handling if this pipeline owns music
  imports.
- Do not run broad destructive filesystem commands against an Unraid
  `/mnt/user` share. Prefer narrowly scoped moves and take backups before
  library-wide cleanup.
- Treat `music-reprocess.sh` as a manual maintenance tool, not an unattended
  cron job.

## Public Repo Notes

This branch removes hardcoded runtime values from the scripts and moves them
into config files. If this repository was private before publication, remember
that making the existing repository public exposes its Git history too. For a
fully clean public release, publish from a sanitized history or a fresh repo.
