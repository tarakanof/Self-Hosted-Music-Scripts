# ADR: Pipeline-led architecture for Lidarr and beets

**Date:** 2026-04-20
**Status:** Accepted

## Context

Lidarr and a custom post-processing pipeline can both observe completed
Transmission downloads. If both systems import the same music files, the library
can end up with duplicate moves, inconsistent metadata, or confusing queue
state.

The project chooses one importer for music: the pipeline delegates music import
to beets, while Lidarr remains responsible for discovery, monitoring, and search.

## Decision

Use a pipeline-led music import flow:

1. Lidarr searches and sends downloads to Transmission.
2. Transmission downloads files.
3. `music-pipeline.sh` processes completed downloads.
4. Music is converted/imported through beets.
5. After a successful import, the pipeline asks Lidarr to refresh the artist.
6. `music-lidarr-sync.sh` periodically audits Lidarr against beets.

Lidarr Completed Download Handling should be disabled for this flow.

## Alternatives Considered

| Option | Result |
|---|---|
| Lidarr-led imports | Simpler, but skips beets enrichment and conversion workflow. |
| Pipeline-led imports | More moving parts, but consistent beets-quality imports. |
| Label-routed hybrid | Flexible, but two import paths create inconsistent output. |
| Custom Lidarr import script | Tighter integration, but coupled to Lidarr's script contract. |
| Dedicated coordinator service | Better observability, but much more maintenance. |

## Consequences

- beets is the source of truth for imported music.
- Lidarr remains the discovery and monitoring frontend.
- Sync and health-check scripts are important safety nets.
- Runtime details must be configurable because deployments differ.
- Failures are handled through logs, review folders, and manual follow-up rather
  than a web UI.

## Revisit If

- Manual recovery becomes frequent.
- Sync drift becomes hard to diagnose from reports.
- Operators need a UI for retry/re-import actions.
- Multiple users or a much larger library make Bash maintenance too limiting.
