# handbrake-encode

`encode.sh` wraps [HandBrakeCLI](https://handbrake.fr/docs/en/latest/cli/cli-options.html): it picks x264 or x265 from the source resolution, keeps the best audio, runs in a detachable `screen` session, verifies the output, and replaces the source.

## Requirements

- [HandBrakeCLI](https://handbrake.fr/), [mediainfo](https://mediaarea.net/en/MediaInfo) and [screen](https://www.gnu.org/software/screen/)
- Bash 3.2 or later; macOS, Linux and WSL (which uses `HandBrakeCLI.exe` from the Windows PATH)

## Install

Clone the repository and run `./encode.sh`, or copy `encode.sh` onto your PATH.

## Usage

| Command | Does |
|---|---|
| `./encode.sh -f movie.mkv` | Encode one file |
| `./encode.sh -d /path/to/movies` | Encode every `.mkv` under the directory, one at a time |
| `./encode.sh -a -f anime.mkv` | Anime tune and bitrate |
| `./encode.sh -e /mnt/SSD -f movie.mkv` | Encode on a scratch drive (default `/mnt/SSD`) |
| `screen -r encoding` | Watch a running encode |

Output lands beside the source as `<name>-x264.mkv` or `<name>-x265.mkv`. **The source is deleted** once the output exists and its duration is within 5 % of the source; on failure the source is kept. Set `ENCODE_POOLS` to fix the x265 thread-pool count, and `ENCODE_WRAPPER` to run the detached encode under a command such as a job lease (`ENCODE_WRAPPER="flock /tmp/jobs.lock"`).

## Documentation

- [Architecture](docs/architecture.md) — codec, bitrate, audio and subtitle rules; scratch workflow; queue
- [Development](docs/development.md) — the gate and releases
- [Decisions](docs/decisions.md) — settled design choices
- [Changelog](CHANGELOG.md)

## License

GNU General Public License; see the header of `encode.sh`.
