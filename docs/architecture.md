# Architecture

`encode.sh` is one Bash script. `main` parses options, checks dependencies, and relaunches
itself inside `screen -S encoding` with the hidden `--_internal` flag, so an encode survives an
SSH disconnect. `ENCODE_WRAPPER`, when set, is shell words that run before the internal run,
so a caller's job lease covers the whole worker. The internal run takes the queue lock and
encodes one file or a directory.

## Codec and bitrate

`mediainfo` reads the first video stream's height; Dolby Vision dual-layer sources carry a
second stream, which is ignored.

| Tier | Height | Codec | Film kbit/s | Anime kbit/s | VBV buffer |
|---|---|---|---|---|---|
| SD/720p | < 1080 | x264 | 7010 | 2460 | 20000 |
| 1080p | 1080–2159 | x264 | 14020 | 4920 | 30000 |
| 2160p | ≥ 2160 | x265 10-bit | 18700 | 6560 | 40000 |

- x264: two-pass ABR at the table bitrate, preset `placebo`, High 4.1, tune `film` or
  `animation`.
- x265: Main10 5.1, `-q 16` with VBV capped at the buffer, preset `veryslow` (`slower` for
  anime), `hdr10:hdr10-opt`, no SAO, deblock `-1,-1`. HandBrake carries the source's HDR
  metadata; the script does not detect HDR.
- Threads: `nproc − 2` (`hw.ncpu − 2` on macOS), passed to x265 only as `pools=`;
  `ENCODE_POOLS` overrides it. x264 uses HandBrake's default threading.
- Frames are never cropped or scaled: `--crop 0:0:0:0`, no `-X`/`-Y`.

## Audio and subtitles

Tracks are read as `position:format:language`.

1. The main track is the first DTS track, else the first TrueHD/MLP track. Within each format
   English (`en*`) comes first, then any language; format outranks language, so a non-English
   DTS track wins over English TrueHD.
2. The compatibility track is the first AC-3 or E-AC-3 track **in the main track's language**,
   so a dual-audio source never gains a second language. The match is on the exact language
   tag. A main track with an empty tag names no language to match: the compatibility track is
   then the first English AC-3/E-AC-3 track, else the first in any language, tagged or not.
3. Both pass through (`-E copy`). With neither, the first AC-3/E-AC-3 track, else track 1.

Subtitles: a foreign audio `scan` plus tracks 1–10, native language English. HandBrake drops
the Matroska default and forced flags and offers no option to keep them: `--subtitle-default=N`
also sets forced in 1.11.2 and stops doing so after upstream fa492f94354a. After validation,
`copy_subtitle_flags` reads each of the first ten source tracks' flags with `mediainfo` and sets
them on the output with `mkvpropedit`, matching tracks in order. A scan hit is the output's
first track and shows only forced events, so it is set default and forced and the rest shift by
one. Any other difference in track count fails the encode.

## Replacing the source

The source is copied to the scratch directory (`-e`, default `/mnt/SSD`), encoded there, and
the output moved back. When the scratch directory is the source directory, HandBrake writes
beside the source; the two are compared with `-ef`, so a symlink or a second mount path to the
source directory counts as the same. A scratch directory missing at runtime falls back to the
source directory with a warning.

The source is deleted only after HandBrake exits 0, the output exists, both durations parse,
they differ by ≤ 5 %, the subtitle flags were copied, and the move back succeeded. Any failure deletes the scratch copy and the
partial output and keeps the source; a failed move leaves the output in the scratch directory
and says so. One statement removes the scratch copy, and it skips a file that is the source
itself. Every step checks its status explicitly because directory mode runs `encode_file`
under `||`, where `set -e` does not apply.

## Directory mode and the queue

`-d` lists `*.mkv` under the directory recursively, excluding `*-x264.mkv` and `*-x265.mkv`, and
reads the list on file descriptor 3: HandBrakeCLI reads stdin for key commands and would consume
a list fed there. A failed file is reported and skipped; the run exits 1 if any failed.

One encode runs per `$TMPDIR`. The internal run makes a private directory with `mkdir`, puts
an empty `pid.<PID>` marker in it and renames it to `$TMPDIR/encode.lock`, so the lock never
exists without its holder's marker; it removes the lock on exit. A second run polls every 30 s.
It takes over a lock whose PID is dead by renaming the marker to its own: the rename succeeds
for one waiter only, and the lock directory stays in place throughout. A marker naming the
waiter's own PID belonged to a dead predecessor and is taken over too. A lock directory with no
marker has no holder; `rmdir` removes it only while it is empty. A run whose rename lands
inside a lock that appeared meanwhile removes its own private directory; if it was killed first,
a waiter removes that directory once its PID is dead, never a live run's. A `pid` file holding the PID,
which copies before this scheme wrote, is read as a marker. Not handled: a PID reused by an
unrelated live process keeps the lock until that process exits. Logs go to
`$TMPDIR/encode-<name>.log`.

## WSL

WSL is detected from `$WSL_DISTRO_NAME` or `/proc/version`. The script then runs
`HandBrakeCLI.exe` and converts only its `--input` and `--output` with `wslpath -w`; every
shell-side operation uses WSL paths.
