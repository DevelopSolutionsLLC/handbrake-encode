# Changelog

All notable changes to this project are documented here. The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and versions follow [SemVer](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed

- x264 runs preset `veryslow` instead of `placebo`, with a turbo first pass and HandBrake's GOP instead of the Blu-ray 1-second GOP, `me=tesa` and settings the presets already set. Streaming Learning Center's x264 preset test put `placebo` at about 3 times `veryslow`'s encode time for a slight quality drop; at 1080p Level 4.1 both presets are held to 4 reference frames.
- `-a` uses preset `slower` on both encoders, so anime encodes faster than film, and replaces the animation tune with explicit settings that keep CGI texture: x264 `bframes=8:aq-mode=3:aq-strength=0.8:psy-rd=0.8,0:deblock=-1,-1`, x265 `psy-rd=1.5:no-strong-intra-smoothing`. The tune's `psy-rd` 0.4 and weak AQ flattened texture, and on x264 its deblock 1:1 smoothed it further.
- 2160p `-a` keeps x265's default `aq-mode` 2. On a 20 s 4K Dolby Vision clip at CRF 18, `aq-mode=3` produced 12.0 MB against 7.2 MB without it; the chosen settings encoded in 349 s, against 353 s for the old `-a` and 703 s for film (#13).
- 2160p `-a` encodes at CRF 18 instead of 16. The 2160p table bitrates are gone: `-q` overrode them, so they never applied.
- x265 no longer forces `hdr10:hdr10-opt`. HandBrake sets `hdr10-opt` and passes the mastering display and content light level for an HDR10 source, and x265 then emits the HDR10 SEI; forced on an SDR 2160p source, `hdr10-opt` only logged an x265 error.

### Fixed

- Subtitle default and forced flags survive the encode: HandBrake dropped them, so a source's forced track no longer showed on its own in Plex. The flags are copied from the source with `mkvpropedit`; a subtitle track-count mismatch keeps the source.
- An output that lost the source's Dolby Vision or HDR10 metadata keeps the source. A HandBrakeCLI built without libdovi, such as Homebrew's or Debian's, dropped Dolby Vision and exited 0, and the source was deleted.
- Directory mode no longer stops after the first file: it waited on its own PID, and HandBrakeCLI could consume the file list from stdin.
- Directory mode skips earlier outputs (`*-x264.mkv`, `*-x265.mkv`) instead of re-encoding them.
- A failed copy, encode or move keeps the source in directory mode too; previously a failed move from the scratch directory still deleted it.
- Audio takes the first DTS track, else the first TrueHD/MLP track, preferring English within each format, so DTS in any language still wins over English TrueHD. The compatibility track is kept only in the main track's language; a Hindi E-AC-3 track no longer rides along with English TrueHD. When the main track has no language tag, the compatibility track is the first English AC-3/E-AC-3 track, else the first in any language.
- Two queued runs no longer start together when the running encode finishes.
- Sources with two video streams report the first stream's resolution.
- A scratch directory (`-e`) that is the source directory under another path, such as a symlink, encodes in place; previously the copy onto itself failed and the cleanup deleted the source.
- Two waiters that saw the same dead lock holder no longer both start: the second deleted the lock the first had just re-created.
- A lock whose holder died before recording its PID, that names the waiting run's own reused PID, or that holds only a dead run's leftover directory is reclaimed instead of blocking the queue forever.

### Changed

- `mkvpropedit` (MKVToolNix) is a required dependency.
- The queue lock is `$TMPDIR/encode.lock` (a directory) holding a `pid.<PID>` marker; logs go to `$TMPDIR`.
- `ENCODE_POOLS` overrides the x265 pool count.
- A bare `encode.sh` prints usage and exits 0; dependencies are checked after options parse.
- `AGENTS.md` replaces `CLAUDE.md`; documentation follows the Cadence repository standard.

### Added

- A Dolby Vision source is tested with a 2 s encode before the full one: a HandBrakeCLI without libdovi stops it and keeps the source. `ENCODE_ALLOW_DV_LOSS=1` turns that into a warning and accepts HDR10-only output.
- `ENCODE_WRAPPER` runs the detached worker under a caller's command, such as a job lease.
- `tests/run.sh`, the gate: `bash -n`, `shellcheck` and behaviour checks against stubbed tools.
