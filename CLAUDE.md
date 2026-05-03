# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

HandBrakeCLI wrapper script for video transcoding. The single script `encode.sh` auto-selects codec based on source resolution detected via `mediainfo`.

## encode.sh — Unified Encoder

```bash
./encode.sh -f media.mkv              # single file
./encode.sh -d /path/to/dir           # all .mkv files, sequential queue
./encode.sh -a -f anime.mkv           # anime mode
./encode.sh -e /fast/ssd -f big.mkv   # use scratch dir for encoding
```

Flags: `-f FILE`, `-d DIR`, `-a` (anime tune + bitrate), `-e DIR` (encode scratch directory; default: `/mnt/SSD`).

Output is placed alongside the source as `{stem}-x264.mkv` or `{stem}-x265.mkv`. On success the original source file is deleted.

### Codec selection and bitrate table

| Tier | Height | Codec | Film Bitrate | Anime Bitrate | VBV Buffer |
|------|--------|-------|-------------|--------------|------------|
| 720p | < 1080 | x264 | 7010 | 2460 | 20000 |
| 1080p | 1080–2159 | x264 | 14020 | 4920 | 30000 |
| 2160p+ | >= 2160 | x265 | 18700 | 6560 | 40000 |

- x264: two-pass, `--x264-preset placebo`, High 4.1
- x265: CRF 16, `--encoder-preset slower`, Main10 5.1, HDR10 enabled for 2160p+

### Encode directory workflow (-e)

Copies source to scratch dir, encodes there, validates output duration (within 5% of source), moves output back to original directory, deletes both copy and original on success. On failure: original is kept, scratch artifacts are cleaned up. If the scratch directory does not exist at runtime, a warning is printed and encoding falls back to the source directory.

### WSL support

Detected at init via `$WSL_DISTRO_NAME` (env var, fast) with `/proc/version` grep as fallback. On WSL, `check_deps` resolves `HandBrakeCLI.exe` instead of `HandBrakeCLI`. All shell-side operations (`cp`, `mv`, `rm`, `mediainfo`, `validate_output`) use WSL paths throughout; only the `--input`/`--output` arguments passed to HandBrakeCLI are converted to Windows paths via `wslpath -w` (`to_win_path()`).

### Queue system

- All work runs inside a detached `screen` session named `encoding` (survives SSH disconnect); attach with `screen -r encoding`
- Directory mode processes files sequentially within one screen session
- PID file (`/tmp/encode.pid`) prevents concurrent encodes; uses `kill -0` (works on macOS, Linux, WSL)
- Script re-invokes itself inside screen via a hidden `--_internal` flag

### Key design choices

- `--crop 0:0:0:0`: auto-crop is disabled — source frame is preserved exactly
- No hardcoded `-X`/`-Y` dimensions — source resolution is preserved
- Thread count: `nproc - 3` (or `sysctl hw.ncpu - 3` on macOS), reserving 3 logical CPUs for system headroom
- Smart audio: selects first lossless track (DTS › TrueHD/MLP) + first AC-3 track and passes both through with `-E copy`; falls back to track 1 if neither is found
- Subtitles: adds `scan` + tracks 1–10, defaults to the scanned forced subtitle, so foreign-language forced subs are included automatically
- x265 path enables HDR10 via `hdr10:hdr10-opt` encopts; no SAO (`no-sao`), deblock `-1,-1`

## Dependencies

HandBrakeCLI, mediainfo, screen — all checked at startup via `check_deps()`.
