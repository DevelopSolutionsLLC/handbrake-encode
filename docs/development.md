# Development

## Gate

`tests/run.sh` is the only test entry point. It runs `bash -n` and `shellcheck` on both
scripts, then drives `encode.sh` against stub `HandBrakeCLI`, `mediainfo`, `mkvpropedit` and a `screen`
that runs the worker in the foreground, in a temporary directory with its own `TMPDIR`.
Each check is limited to 10 s and reports its duration. The stub HandBrakeCLI reads stdin
like the real one.

| Check | Protects |
|---|---|
| static | syntax and shellcheck findings |
| usage | a bare command prints usage and exits 0 |
| directory | each source encoded once, outputs skipped, a failure keeps its source |
| audio | English first within the lossless format; the compatibility track matches its language, or is English first when the main track is untagged |
| x264 tier | a 1080p source takes x264 at the 1080p bitrate and the `-x264` suffix |
| duration | an output more than 5 % off the source's duration is removed and the source kept |
| subtitle flags | source flags are copied in order, shifted by one after a scan hit; a track-count mismatch keeps the source |
| HDR guard | an output that lost Dolby Vision or HDR10 is removed and the source kept |
| DV probe | a HandBrakeCLI that drops Dolby Vision stops a Dolby Vision source before encoding, from the launcher too; `ENCODE_ALLOW_DV_LOSS=1` warns and encodes |
| stale lock | a dead holder's lock is reclaimed and the run releases its own |
| scratch alias | a scratch path that resolves to the source directory never costs the source |
| orphan lock | a lock directory without a holder's marker is reclaimed |
| nested orphan | a dead publisher's private directory stranded inside the lock is cleared |
| lock race | a waiter that saw a dead PID leaves the lock alone once another waiter holds it |
| own-pid lock | a dead holder's lock naming the run's own reused PID is reclaimed |
| wrapper | the launcher runs the worker under `ENCODE_WRAPPER`'s words, and bare when unset |

`ENCODE_SCRIPT=/path/to/old/encode.sh tests/run.sh` runs the behaviour checks against another
copy; each check but `x264 tier` and `duration` fails against the release before 2026-11-20.
The stub `mediainfo` reports 1920x1080 for a source named `*1080*` and half the duration for
the output of a source named `*short*`. The lock race check swaps in a
`cat` or `mv` stub that hands the lock to a live PID at the moment a second waiter would.

Review-only: the header line, one-line function comments and the 80-column comment limit;
ShellCheck 0.11 has no check for them. The gate runs on the machine's `bash`; run it under
`/bin/bash` 3.2 on macOS before a release.

## Releases

Versions follow SemVer 2.0.0 and `CHANGELOG.md` follows Keep a Changelog. To release, move
`Unreleased` under a version heading, commit, and tag `vX.Y.Z`.
