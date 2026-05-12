# handbrake-encode

A unified video encoding script that wraps [HandBrakeCLI](https://handbrake.fr/docs/en/latest/cli/cli-options.html) with smart defaults for high-quality encodes.

Automatically selects **x264** or **x265** based on source resolution, detects HDR, picks the best audio tracks, and manages encoding jobs in background screen sessions that survive SSH disconnects.

## Requirements

- [HandBrakeCLI](https://handbrake.fr/)
- [mediainfo](https://mediainfo.sourceforge.net/)
- [screen](https://www.gnu.org/software/screen/)

### WSL (Windows Subsystem for Linux)

Fully supported. The script detects WSL automatically and uses `HandBrakeCLI.exe` from your Windows PATH. Pass WSL paths as normal (e.g. `/mnt/c/Drop/movie.mkv`) — path conversion to Windows format is handled internally.

## Usage

```bash
# Single file
./encode.sh -f movie.mkv

# All .mkv files in a directory (sequential queue)
./encode.sh -d /path/to/movies/

# Anime mode (adjusts tune and bitrate)
./encode.sh -a -f anime.mkv

# Use a fast scratch drive for encoding
./encode.sh -e /mnt/SSD -f movie.mkv
```

### Flags

| Flag | Description |
|------|-------------|
| `-f FILE` | Single file to encode |
| `-d DIR` | Encode all `.mkv` files in directory sequentially |
| `-a` | Anime mode (tune + lower bitrate) |
| `-e DIR` | Scratch directory for encoding (default: `/mnt/SSD`) |

## How it works

### Codec selection

The source resolution is detected via `mediainfo`. The codec is chosen automatically:

- **Height < 2160**: x264 (H.264 High profile, Level 4.1, two-pass placebo)
- **Height >= 2160**: x265 10-bit (HEVC Main10, Level 5.1, CRF 16, HDR10; film veryslow, anime slower)

No dimensions are hardcoded -- source resolution is preserved as-is.

### Bitrate table

| Tier | Height | Codec | Film | Anime | VBV Buffer |
|------|--------|-------|------|-------|------------|
| 720p | < 1080 | x264 | 7010 | 2460 | 20000 |
| 1080p | 1080-2159 | x264 | 14020 | 4920 | 30000 |
| 2160p+ | >= 2160 | x265 | 18700 | 6560 | 40000 |

### Audio selection

Intelligently selects audio tracks using `mediainfo`:
1. Finds the first lossless track (DTS/TrueHD/MLP)
2. Finds the first AC-3 compatibility track
3. Passes both through without re-encoding

### Encode directory workflow (`-e`)

When a scratch directory is specified:
1. Copies the source file to the scratch drive
2. Encodes there (faster on SSD/tmpfs)
3. Validates the output by comparing duration to source (within 5%)
4. On success: moves output back to the original directory, deletes both the copy and original
5. On failure: keeps the original, cleans up scratch artifacts

If the scratch directory does not exist at runtime, a warning is printed and the encode proceeds alongside the source file instead of aborting.

### Screen sessions and queueing

All encodes run inside a detached `screen` session, so they survive SSH disconnects. In directory mode, files are processed sequentially. A PID file (`/tmp/encode.pid`) prevents concurrent encodes.

```bash
# Check on a running encode
screen -r encoding
```

## License

GNU General Public License -- see source for details.
