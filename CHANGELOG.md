# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow [SemVer](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- Directory mode no longer stops after the first file: it waited on its own PID, and HandBrakeCLI could consume the file list from stdin.
- Directory mode skips earlier outputs (`*-x264.mkv`, `*-x265.mkv`) instead of re-encoding them.
- A failed copy, encode or move keeps the source in directory mode too; previously a failed move from the scratch directory still deleted it.
- Audio prefers English and keeps the compatibility track only in the main track's language; a Hindi E-AC-3 track no longer rides along with English TrueHD.
- Two queued runs no longer start together when the running encode finishes.
- Sources with two video streams report the first stream's resolution.

### Changed

- The queue lock is `$TMPDIR/encode.lock` (a directory); logs go to `$TMPDIR`.
- `ENCODE_POOLS` overrides the x265 pool count.
- A bare `encode.sh` prints usage and exits 0; dependencies are checked after options parse.
- `AGENTS.md` replaces `CLAUDE.md`; documentation follows the Cadence repository standard.

### Added

- `tests/run.sh`, the gate: `bash -n`, `shellcheck` and behaviour checks against stubbed tools.
