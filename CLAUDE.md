# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

HandBrakeCLI wrapper scripts for video transcoding. The primary script is `encode.sh`, which auto-selects codec based on source resolution. Legacy per-codec scripts (`x264-encode.sh`, `x265-encode.sh`) are retained for reference.

## encode.sh — Unified Encoder

Auto-selects x264 (< 2160p) or x265 (>= 2160p) based on source height detected via mediainfo. Runs all encodes in a detached `screen` session. Logs to `/tmp/`.

```bash
./encode.sh -f media.mkv              # single file
./encode.sh -d /path/to/dir           # all .mkv files, sequential queue
./encode.sh -a -f anime.mkv           # anime mode
./encode.sh -e /fast/ssd -f big.mkv   # use scratch dir for encoding
```

Flags: `-f FILE`, `-d DIR`, `-a` (anime tune + bitrate), `-e DIR` (encode scratch directory).

### Codec selection and bitrate table

| Tier | Height | Codec | Film Bitrate | Anime Bitrate | VBV Buffer |
|------|--------|-------|-------------|--------------|------------|
| 720p | < 1080 | x264 | 7010 | 2460 | 20000 |
| 1080p | 1080–2159 | x264 | 14020 | 4920 | 30000 |
| 2160p+ | >= 2160 | x265 | 18700 | 6560 | 40000 |

### Encode directory workflow (-e)

Copies source to scratch dir, encodes there, validates output duration (within 5% of source), moves output back to original directory, deletes both copy and original on success.

### Queue system

- All work runs inside a `screen` session (survives SSH disconnect)
- Directory mode processes files sequentially within one screen session
- PID file (`/tmp/encode.pid`) prevents concurrent encodes; uses `kill -0` (cross-platform: macOS, Linux, WSL)
- Script re-invokes itself inside screen via a hidden `--_internal` flag

### Key design choices

- No hardcoded `-X`/`-Y` dimensions — source resolution is preserved
- Smart audio selection for both codecs: muxes DTS/TrueHD/MLP + AC-3 via mediainfo detection
- x265 path enables HDR10 automatically for 2160p+ sources
- x264 uses two-pass placebo; x265 uses CRF 16 veryslow

## Dependencies

HandBrakeCLI, mediainfo, screen — all checked at startup.

