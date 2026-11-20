# Development

## Gate

`tests/run.sh` is the only test entry point. It runs `bash -n` and `shellcheck` on both
scripts, then drives `encode.sh --_internal` against stub `HandBrakeCLI`, `mediainfo` and
`screen` in a temporary directory with its own `TMPDIR`. Each check is limited to 10 s and
reports its duration. The stub HandBrakeCLI reads stdin like the real one.

| Check | Protects |
|---|---|
| static | syntax and shellcheck findings |
| usage | a bare command prints usage and exits 0 |
| directory | each source encoded once, outputs skipped, a failure keeps its source |
| audio | English lossless first; the compatibility track matches its language |
| stale lock | a dead holder's lock is reclaimed and the run releases its own |

`ENCODE_SCRIPT=/path/to/old/encode.sh tests/run.sh` runs the behaviour checks against another
copy; each check fails against the release before 2026-11-20.

Review-only: the header line, one-line function comments and the 80-column comment limit;
ShellCheck 0.11 has no check for them. The gate runs on the machine's `bash`; run it under
`/bin/bash` 3.2 on macOS before a release.

## Releases

Versions follow SemVer 2.0.0 and `CHANGELOG.md` follows Keep a Changelog. To release, move
`Unreleased` under a version heading, commit, and tag `vX.Y.Z`.
