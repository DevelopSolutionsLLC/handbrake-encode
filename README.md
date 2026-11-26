# handbrake-encode

`encode.sh` wraps [HandBrakeCLI](https://handbrake.fr/docs/en/latest/cli/cli-options.html): it picks x264 or x265 from the source resolution, keeps the best audio, runs in a detachable `screen` session, verifies the output, and replaces the source.

## Requirements

- [HandBrakeCLI](https://handbrake.fr/), [mediainfo](https://mediaarea.net/en/MediaInfo), [MKVToolNix](https://mkvtoolnix.download/) (`mkvpropedit`) and [screen](https://www.gnu.org/software/screen/)
- For Dolby Vision, a HandBrakeCLI built with libdovi: the official release builds are; Homebrew's `handbrake` and Debian's `handbrake-cli` are not. No version or option reports libdovi, so for a Dolby Vision source `encode.sh` first encodes 2 s and stops, keeping the source, when Dolby Vision does not survive; `ENCODE_ALLOW_DV_LOSS=1` makes that a warning and accepts HDR10-only output
- Bash 3.2 or later; macOS, Linux and WSL (which uses `HandBrakeCLI.exe` from the Windows PATH)

## Install

Clone the repository and run `./encode.sh`, or copy `encode.sh` onto your PATH.

## Usage

| Command | Does |
|---|---|
| `./encode.sh -f movie.mkv` | Encode one file |
| `./encode.sh -d /path/to/movies` | Encode every `.mkv` under the directory, one at a time |
| `./encode.sh -a -f anime.mkv` | Anime preset, tweaks and rate |
| `./encode.sh -e /mnt/SSD -f movie.mkv` | Encode on a scratch drive (default `/mnt/SSD`) |
| `screen -r encoding` | Watch a running encode |

Output lands beside the source as `<name>-x264.mkv` or `<name>-x265.mkv`. **The source is deleted** once the output exists, its duration is within 5 % of the source, it keeps the source's Dolby Vision and HDR10 metadata, and the source's subtitle default and forced flags are copied onto it; on failure the source is kept. Set `ENCODE_POOLS` to fix the x265 thread-pool count, and `ENCODE_WRAPPER` to run the detached encode under a command such as a job lease (`ENCODE_WRAPPER="flock /tmp/jobs.lock"`).

## Documentation

- [Architecture](docs/architecture.md) — codec, bitrate, audio and subtitle rules; scratch workflow; queue
- [Development](docs/development.md) — the gate and releases
- [Decisions](docs/decisions.md) — settled design choices
- [Changelog](CHANGELOG.md)

## License

GNU General Public License; see the header of `encode.sh`.
