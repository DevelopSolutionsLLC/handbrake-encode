# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow [SemVer](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- Directory mode no longer stops after the first file: it waited on its own PID, and HandBrakeCLI could consume the file list from stdin.
- Directory mode skips earlier outputs (`*-x264.mkv`, `*-x265.mkv`) instead of re-encoding them.
- A failed copy, encode or move keeps the source in directory mode too; previously a failed move from the scratch directory still deleted it.
- Audio takes the first DTS track, else the first TrueHD/MLP track, preferring English within each format, so DTS in any language still wins over English TrueHD. The compatibility track is kept only in the main track's language; a Hindi E-AC-3 track no longer rides along with English TrueHD. When the main track has no language tag, the compatibility track is the first English AC-3/E-AC-3 track, else the first in any language.
- Two queued runs no longer start together when the running encode finishes.
- Sources with two video streams report the first stream's resolution.
- A scratch directory (`-e`) that is the source directory under another path, such as a symlink, encodes in place; previously the copy onto itself failed and the cleanup deleted the source.
- Two waiters that saw the same dead lock holder no longer both start: the second deleted the lock the first had just re-created.
- A lock whose holder died before recording its PID, that names the waiting run's own reused PID, or that holds only a dead run's leftover directory is reclaimed instead of blocking the queue forever.

### Changed

- The queue lock is `$TMPDIR/encode.lock` (a directory) holding a `pid.<PID>` marker; logs go to `$TMPDIR`.
- `ENCODE_POOLS` overrides the x265 pool count.
- A bare `encode.sh` prints usage and exits 0; dependencies are checked after options parse.
- `AGENTS.md` replaces `CLAUDE.md`; documentation follows the Cadence repository standard.

### Added

- `tests/run.sh`, the gate: `bash -n`, `shellcheck` and behaviour checks against stubbed tools.
