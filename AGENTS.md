# handbrake-encode

`encode.sh` wraps HandBrakeCLI: it picks x264 or x265 from the source height, keeps the best
audio, encodes in a detached `screen` session, verifies the output, then deletes the source.

## Responsibilities

- Codec, bitrate, audio and subtitle selection for one source or a directory of `.mkv` files.
- Safe replacement: the source goes only after the output exists, its duration is within 5 %, it
  keeps the source's Dolby Vision and HDR10 metadata and its subtitle flags are copied.
- One encode at a time per `$TMPDIR`, through the `encode.lock` directory.

Not responsible for: writing HDR or Dolby Vision metadata (HandBrake passes it through; the
script only checks it survived), container formats other than `.mkv`, library naming, or
scheduling beyond its own queue.

## Commands

| Command | Does |
|---|---|
| `./encode.sh -f FILE` | encode one file in `screen` session `encoding` |
| `./encode.sh -d DIR` | encode every `.mkv` under `DIR`, skipping `*-x264.mkv` and `*-x265.mkv` |
| `./encode.sh -a …` / `-e DIR` | anime tune and bitrate / scratch directory (default `/mnt/SSD`) |
| `tests/run.sh` | the gate: `bash -n`, `shellcheck`, behaviour against stubbed tools |

## Rules

- **The script deletes its input on success.** Any change to `encode_file` keeps every step's
  status checked explicitly: directory mode calls it under `||`, where `set -e` is off.
- Bash 3.2 is the floor (macOS `/bin/bash`): no `mapfile`, associative arrays or `${var,,}`.
- HandBrakeCLI reads stdin for key commands; never feed a loop's list on stdin.
- `ENCODE_POOLS` overrides the x265 pool count; `TMPDIR` locates the lock and logs;
  `ENCODE_WRAPPER` prefixes the detached worker as shell words.
- Run `tests/run.sh` before every commit; a behaviour change updates `docs/architecture.md`
  and `CHANGELOG.md`.

## Paths

- `encode.sh` — the product. `tests/run.sh` — the gate.
- `docs/architecture.md` — selection rules and workflow. `docs/development.md` — gate and
  release. `docs/decisions.md` — settled decisions.
