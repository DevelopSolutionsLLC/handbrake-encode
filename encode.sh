#!/bin/bash
# Encode video with HandBrakeCLI, verify the output, then replace the source.
# Copyright (c) 2019 Victor T. Chevalier. GNU GPL; no warranty.
set -euo pipefail

TMP_ROOT="${TMPDIR:-/tmp}"
TMP_ROOT="${TMP_ROOT%/}"
LOGDIR="$TMP_ROOT"
LOCK_DIR="$TMP_ROOT/encode.lock"
LOCK_HOLDER=""
HANDBRAKE=""
MEDIAINFO=""
IS_WSL=0

ANIME=0
ENCODE_DIR="/mnt/SSD"
INFILE=""
DIR=""
INTERNAL=0

SRC_WIDTH=0
SRC_HEIGHT=0
BITRATE=0
BUFFER=0
THREADS=1
OPTIONS=""
CODEC_TAG=""
AUDIO_OPTS=""

is_wsl() {
    [[ -n "${WSL_DISTRO_NAME:-}" ]] || grep -qi microsoft /proc/version 2>/dev/null
}
is_wsl && IS_WSL=1

to_win_path() {
    if [[ $IS_WSL -eq 1 ]]; then
        wslpath -w "$1"
    else
        echo "$1"
    fi
}

usage() {
    echo "Usage: $0 [-a] [-e encode_dir] {-f media.mkv | -d dir}"
    echo "  -f FILE   Single file to encode"
    echo "  -d DIR    Encode every .mkv under DIR, one at a time"
    echo "  -a        Anime mode (tune + bitrate)"
    echo "  -e DIR    Scratch directory for encoding (SSD/tmpfs)"
    exit "${1:-0}"
}

check_deps() {
    if [[ $IS_WSL -eq 1 ]]; then
        HANDBRAKE=$(command -v HandBrakeCLI.exe) || true
    else
        HANDBRAKE=$(command -v HandBrakeCLI) || true
    fi
    MEDIAINFO=$(command -v mediainfo) || true
    local screen_bin
    screen_bin=$(command -v screen) || true

    if [[ -z "$HANDBRAKE" ]]; then
        echo "Please install HandBrakeCLI" >&2
        exit 1
    fi
    if [[ -z "$MEDIAINFO" ]]; then
        echo "Please install mediainfo" >&2
        exit 1
    fi
    if [[ -z "$screen_bin" ]]; then
        echo "Please install screen" >&2
        exit 1
    fi
}

detect_threads() {
    if [[ "$(uname)" == "Darwin" ]]; then
        THREADS=$(sysctl -n hw.ncpu)
    else
        THREADS=$(nproc 2>/dev/null || lscpu | grep -E '^CPU\(s\):' | awk '{print $2}')
    fi
    if [[ $THREADS -gt 2 ]]; then
        THREADS=$((THREADS - 2))
    fi
    # A pinned cpuset can measure faster with a set count than nproc - 2.
    if [[ ${ENCODE_POOLS:-} =~ ^[1-9][0-9]*$ ]]; then
        THREADS=$ENCODE_POOLS
    fi
}

detect_resolution() {
    local file="$1"
    SRC_WIDTH=$("$MEDIAINFO" --Inform="Video;%Width%\n" "$file")
    SRC_HEIGHT=$("$MEDIAINFO" --Inform="Video;%Height%\n" "$file")
    # Dolby Vision dual-layer sources carry a second video stream.
    SRC_WIDTH=${SRC_WIDTH%%$'\n'*}
    SRC_HEIGHT=${SRC_HEIGHT%%$'\n'*}

    if [[ ! $SRC_WIDTH =~ ^[1-9][0-9]*$ || ! $SRC_HEIGHT =~ ^[1-9][0-9]*$ ]]; then
        echo "ERROR: Cannot detect resolution for: $file" >&2
        return 1
    fi
}

validate_input_file() {
    local file="$1"

    if [[ ! -f "$file" ]]; then
        echo "ERROR: File not found: $file" >&2
        return 1
    fi
    if [[ ! -r "$file" ]]; then
        echo "ERROR: File is not readable: $file" >&2
        echo "Fix permissions, for example: chmod u+r -- \"$file\"" >&2
        return 1
    fi
}

lookup_bitrate() {
    local height="$1"
    local anime="$2"

    if [[ $height -ge 2160 ]]; then
        if [[ "$anime" == "1" ]]; then
            BITRATE=6560
        else
            BITRATE=18700
        fi
        BUFFER=40000
    elif [[ $height -ge 1080 ]]; then
        if [[ "$anime" == "1" ]]; then
            BITRATE=4920
        else
            BITRATE=14020
        fi
        BUFFER=30000
    else
        if [[ "$anime" == "1" ]]; then
            BITRATE=2460
        else
            BITRATE=7010
        fi
        BUFFER=20000
    fi
}

# Print "pos:lang" of the first track matching a format regex: in language $3
# when non-empty, else English first, then any language.
pick_track() {
    local info="$1" format="$2" lang="${3:-}"
    awk -F: -v re="$format" -v lang="$lang" '
        tolower($2) ~ re {
            if (lang != "" ? $3 == lang : $3 ~ /^en/) { print $1 ":" $3; found = 1; exit }
            if (lang == "" && first == "") first = $1 ":" $3
        }
        END { if (!found && first != "") print first }' <<< "$info"
}

detect_audio_tracks() {
    local file="$1"
    local info lossless compat
    info=$("$MEDIAINFO" --Inform="Audio;%StreamKindPos%:%Format%:%Language%\n" "$file")

    lossless=$(pick_track "$info" '^dts')
    [[ -n "$lossless" ]] || lossless=$(pick_track "$info" '^(truehd|mlp)')
    # The compatibility track matches the main track's language; an untagged
    # main track names none, so the pick falls back to English, then any.
    if [[ -n "$lossless" ]]; then
        compat=$(pick_track "$info" '^(e-)?ac-3' "${lossless#*:}")
    else
        compat=$(pick_track "$info" '^(e-)?ac-3')
    fi
    lossless=${lossless%%:*}
    compat=${compat%%:*}

    if [[ -n "$lossless" && -n "$compat" && "$lossless" != "$compat" ]]; then
        AUDIO_OPTS="-a ${lossless},${compat} -E copy"
    elif [[ -n "$lossless" ]]; then
        AUDIO_OPTS="-a ${lossless} -E copy"
    elif [[ -n "$compat" ]]; then
        AUDIO_OPTS="-a ${compat} -E copy"
    else
        AUDIO_OPTS="-a 1 -E copy"
    fi
}

build_encoder_options() {
    local infile="$1"

    detect_resolution "$infile" || return 1
    lookup_bitrate "$SRC_HEIGHT" "$ANIME"
    detect_audio_tracks "$infile"
    detect_threads

    OPTIONS="--crop 0:0:0:0 --auto-anamorphic --markers"
    OPTIONS="$OPTIONS $AUDIO_OPTS"
    OPTIONS="$OPTIONS --native-language eng --subtitle scan,1,2,3,4,5,6,7,8,9,10 --subtitle-default scan --subtitle-forced scan"

    if [[ $SRC_HEIGHT -ge 2160 ]]; then
        CODEC_TAG="x265"
        local preset="veryslow"
        local tune_opt=""
        if [[ "$ANIME" == "1" ]]; then
            preset="slower"
            tune_opt="--encoder-tune animation"
        fi

        OPTIONS="$OPTIONS --encoder x265_10bit --encoder-profile main10 --encoder-level 5.1"
        OPTIONS="$OPTIONS -q 16 --encoder-preset $preset $tune_opt"
        OPTIONS="$OPTIONS --encopts pools=${THREADS}:no-sao:selective-sao=0:deblock=-1,-1:hdr10:hdr10-opt:bitrate=${BITRATE}:vbv-maxrate=${BUFFER}:vbv-bufsize=${BUFFER}"
        OPTIONS="$OPTIONS --no-decomb --no-deinterlace"
    else
        CODEC_TAG="x264"
        local tune="film"
        if [[ "$ANIME" == "1" ]]; then
            tune="animation"
        fi

        OPTIONS="$OPTIONS --encoder x264 --encoder-tune $tune --multi-pass --x264-preset placebo"
        OPTIONS="$OPTIONS --encopts rc-lookahead=60:b-adapt=2:me=tesa:nal_hrd=vbr:min-keyint=1:keyint=24:bitrate=${BITRATE}:vbv-maxrate=${BUFFER}:vbv-bufsize=${BUFFER}:ratetol=1.0"
        OPTIONS="$OPTIONS --h264-profile high --h264-level 4.1"
        OPTIONS="$OPTIONS --vb $BITRATE"
    fi
}

validate_output() {
    local source="$1"
    local output="$2"

    if [[ ! -f "$output" ]]; then
        echo "ERROR: Output file does not exist: $output" >&2
        return 1
    fi

    local src_duration out_duration
    src_duration=$("$MEDIAINFO" --Inform="General;%Duration%" "$source")
    out_duration=$("$MEDIAINFO" --Inform="General;%Duration%" "$output")
    src_duration=${src_duration%%.*}
    out_duration=${out_duration%%.*}

    if [[ ! $src_duration =~ ^[1-9][0-9]*$ || ! $out_duration =~ ^[1-9][0-9]*$ ]]; then
        echo "ERROR: Source or output has no valid duration" >&2
        return 1
    fi

    local diff=$(( src_duration - out_duration ))
    if [[ $diff -lt 0 ]]; then
        diff=$(( -diff ))
    fi
    local tolerance=$(( src_duration / 20 ))
    if [[ $diff -gt $tolerance ]]; then
        echo "WARNING: Duration mismatch — source: ${src_duration}ms, output: ${out_duration}ms" >&2
        return 1
    fi
}

# Each step checks its own status: callers run this under ||, where set -e is
# off, and a missed failure would delete the only good copy.
encode_file() {
    local infile="$1"
    validate_input_file "$infile" || return 1

    local infile_abs src_dir file_basename
    src_dir="$(cd "$(dirname "$infile")" && pwd)" || return 1
    file_basename="$(basename "$infile")"
    infile_abs="${src_dir}/${file_basename}"
    local stem="${file_basename%.*}"

    build_encoder_options "$infile_abs" || return 1

    local work_infile="$infile_abs"
    local final="${src_dir}/${stem}-${CODEC_TAG}.mkv"
    local outfile="$final"
    local logfile="${LOGDIR}/encode-${stem}.log"
    local scratch="" failure="" rc=0

    if [[ -n "$ENCODE_DIR" ]]; then
        scratch="$(cd "$ENCODE_DIR" && pwd)" || return 1
        # -ef sees one directory behind a symlink or a second mount path.
        [[ ! "$scratch" -ef "$src_dir" ]] || scratch=""
    fi
    if [[ -n "$scratch" ]]; then
        work_infile="${scratch}/${file_basename}"
        outfile="${scratch}/${stem}-${CODEC_TAG}.mkv"
        echo "Copying to encode directory: ${scratch}/"
        cp "$infile_abs" "$work_infile" \
            || failure="ERROR: Copy to ${scratch} failed; keeping the original"
    fi

    if [[ -z "$failure" ]]; then
        echo "Encoding: $file_basename (${SRC_WIDTH}x${SRC_HEIGHT}, ${CODEC_TAG}, bitrate=${BITRATE}, buffer=${BUFFER})"
        echo "Log: $logfile"
        echo "Encode command: $HANDBRAKE $OPTIONS --input \"$(to_win_path "$work_infile")\" --output \"$(to_win_path "$outfile")\""

        # shellcheck disable=SC2086
        $HANDBRAKE $OPTIONS --input "$(to_win_path "$work_infile")" --output "$(to_win_path "$outfile")" > "$logfile" 2>&1 || rc=$?

        if [[ $rc -ne 0 ]] || ! validate_output "$work_infile" "$outfile"; then
            failure="ENCODE FAILED: keeping original — $infile_abs"
            rm -f "$outfile"
        elif [[ -n "$scratch" ]] && ! mv "$outfile" "$final"; then
            failure="ERROR: Move failed; original kept, output left at $outfile"
        fi
    fi

    # The only place the scratch copy goes; a hard link to the source stays.
    if [[ -n "$scratch" && ! "$work_infile" -ef "$infile_abs" ]]; then
        rm -f "$work_infile"
    fi
    if [[ -n "$failure" ]]; then
        echo "$failure" >&2
        return 1
    fi
    rm -f "$infile_abs"
    echo "SUCCESS: $final"
}

# The lock appears with its holder's marker already inside, so no waiter
# sees it without one: mkdir a private directory, then rename it into place.
publish_lock() {
    local mine="$LOCK_DIR.$$"
    [[ ! -e "$LOCK_DIR" ]] || return 1
    rm -rf "$mine"
    mkdir "$mine" || return 1
    : > "$mine/pid.$$" || return 1
    mv "$mine" "$LOCK_DIR" 2>/dev/null
    [[ ! -e "$LOCK_DIR/pid.$$" ]] || return 0
    # mv moves into a lock that appeared meanwhile; take the directory back.
    rm -rf "$mine" "${LOCK_DIR:?}/${mine##*/}"
    return 1
}

# Take a dead holder's lock by renaming its marker to ours. rename is atomic,
# so of the waiters that saw one dead pid a single one wins, and the lock
# never vanishes for a second waiter to delete the first's fresh one.
reclaim_lock() {
    local marker stray
    LOCK_HOLDER=""
    # pid.<PID> is the marker; older copies wrote a pid file holding the PID.
    for marker in "$LOCK_DIR"/pid.[0-9]* "$LOCK_DIR/pid"; do
        [[ -f "$marker" ]] || continue
        LOCK_HOLDER=${marker##*/pid.}
        if [[ "$marker" == "$LOCK_DIR/pid" ]]; then
            LOCK_HOLDER=$(cat "$marker" 2>/dev/null) || LOCK_HOLDER=""
        fi
        # A marker naming this PID is a dead predecessor's: PIDs are reused.
        if [[ $LOCK_HOLDER =~ ^[1-9][0-9]*$ && $LOCK_HOLDER != "$$" ]] \
                && kill -0 "$LOCK_HOLDER" 2>/dev/null; then
            return 1
        fi
        [[ "$marker" == "$LOCK_DIR/pid.$$" ]] || mv -f "$marker" "$LOCK_DIR/pid.$$" 2>/dev/null
        return
    done
    # A publisher killed after its mv landed inside a lock leaves its private
    # directory here; a live one removes its own, so only dead PIDs' go.
    for stray in "$LOCK_DIR/${LOCK_DIR##*/}".[0-9]*; do
        [[ -d "$stray" ]] || continue
        if [[ ${stray##*.} == "$$" ]] || ! kill -0 "${stray##*.}" 2>/dev/null; then
            rm -rf "$stray"
        fi
    done
    # No marker means no holder; rmdir removes only an empty directory.
    rmdir "$LOCK_DIR" 2>/dev/null && publish_lock
}

# mkdir is atomic on every platform; flock is absent on macOS.
acquire_lock() {
    until publish_lock || reclaim_lock; do
        echo "Another encode is running (PID ${LOCK_HOLDER:-unknown}). Waiting..." >&2
        sleep 30
    done
    trap release_lock EXIT
}

release_lock() {
    [[ ! -e "$LOCK_DIR/pid.$$" ]] || rm -rf "$LOCK_DIR"
}

build_relaunch_args() {
    local args=("--_internal")
    [[ "$ANIME" == "1" ]] && args+=("-a")
    [[ -n "$ENCODE_DIR" ]] && args+=("-e" "$ENCODE_DIR")
    [[ -n "$INFILE" ]] && args+=("-f" "$INFILE")
    [[ -n "$DIR" ]] && args+=("-d" "$DIR")

    local quoted_args=""
    for arg in "${args[@]}"; do
        quoted_args+="$(printf ' %q' "$arg")"
    done
    echo "$quoted_args"
}

encode_directory() {
    local file failed=0
    # fd 3 keeps the list away from HandBrakeCLI, which reads stdin.
    while IFS= read -r -d '' file <&3; do
        echo "--- Processing: $file ---"
        encode_file "$file" || { failed=1; echo "Skipping failed file: $file" >&2; }
    done 3< <(find "$DIR" -type f -iname '*.mkv' ! -iname '*-x264.mkv' ! -iname '*-x265.mkv' -print0)
    return "$failed"
}

main() {
    [[ $# -gt 0 ]] || usage 0

    if [[ "${1:-}" == "--_internal" ]]; then
        INTERNAL=1
        shift
    fi

    while getopts ":hf:d:ae:" option; do
        case "${option}" in
            a) ANIME=1 ;;
            d) DIR="${OPTARG}" ;;
            e) ENCODE_DIR="${OPTARG}" ;;
            f) INFILE="${OPTARG}" ;;
            h) usage 0 ;;
            *) usage 1 >&2 ;;
        esac
    done

    if [[ -z "$INFILE" && -z "$DIR" ]]; then
        usage 1 >&2
    fi

    check_deps

    if [[ -n "$ENCODE_DIR" && ! -d "$ENCODE_DIR" ]]; then
        echo "WARNING: Scratch directory '$ENCODE_DIR' does not exist — encoding alongside source instead." >&2
        ENCODE_DIR=""
    fi

    if [[ -n "$INFILE" ]]; then
        validate_input_file "$INFILE"
    fi

    if [[ -n "$DIR" && ! -d "$DIR" ]]; then
        echo "ERROR: Directory not found: $DIR" >&2
        exit 1
    fi

    if [[ $INTERNAL -eq 0 ]]; then
        local script_path
        script_path="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
        local relaunch_args
        relaunch_args="$(build_relaunch_args)"

        local launch_cmd
        launch_cmd="PATH=$(printf '%q' "$PATH"); export PATH; exec $(printf '%q' "$script_path")$relaunch_args"

        screen -S "encoding" -dm bash -c "$launch_cmd"
        echo "Encode launched in screen session 'encoding'."
        echo "Attach with: screen -r encoding"
        exit 0
    fi

    acquire_lock

    if [[ -n "$DIR" ]]; then
        encode_directory
    else
        encode_file "$INFILE"
    fi
}

main "$@"
