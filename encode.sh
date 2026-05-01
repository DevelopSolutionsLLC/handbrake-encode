#!/bin/bash
#
# encode.sh — Unified video encoding via HandBrakeCLI
#
# Copyright (c) 2019 Free Software Foundation, Inc.
# This is free software. You may redistribute copies of it under the terms of
# the GNU General Public License.
# There is NO WARRANTY, to the extent permitted by law.
#
# Written by Victor T. Chevalier
#
# Usage:
#   ./encode.sh [-a] [-e dir] -f media.mkv
#   ./encode.sh [-a] [-e dir] -d /path/to/dir
#
set -euo pipefail

LOGDIR="/tmp"
PID_FILE="/tmp/encode.pid"
HANDBRAKE=""
MEDIAINFO=""

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

usage() {
    echo "Usage: $0 [-a] [-e encode_dir] {-f media.mkv | -d dir}" 1>&2
    echo "  -f FILE   Single file to encode" 1>&2
    echo "  -d DIR    Encode all .mkv files in directory (sequential)" 1>&2
    echo "  -a        Anime mode (tune + bitrate)" 1>&2
    echo "  -e DIR    Scratch directory for encoding (SSD/tmpfs)" 1>&2
    exit 1
}

check_deps() {
    HANDBRAKE=$(command -v HandBrakeCLI) || true
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
    if [[ $THREADS -gt 3 ]]; then
        THREADS=$((THREADS - 3))
    fi
}

detect_resolution() {
    local file="$1"
    SRC_WIDTH=$("$MEDIAINFO" --Inform="Video;%Width%" "$file")
    SRC_HEIGHT=$("$MEDIAINFO" --Inform="Video;%Height%" "$file")

    if [[ -z "$SRC_WIDTH" || -z "$SRC_HEIGHT" || "$SRC_WIDTH" == "0" || "$SRC_HEIGHT" == "0" ]]; then
        echo "ERROR: Cannot detect resolution for: $file" >&2
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

detect_audio_tracks() {
    local file="$1"
    local track_info
    track_info=$("$MEDIAINFO" --Inform="Audio;%StreamKindPos%:%Format%\n" "$file")

    local lossless=""
    local ac3=""

    lossless=$(echo "$track_info" | grep -i "DTS" | head -1 | cut -d ':' -f 1)

    if [[ -z "$lossless" ]]; then
        lossless=$(echo "$track_info" | grep -iE "TrueHD|MLP" | head -1 | cut -d ':' -f 1)
    fi

    ac3=$(echo "$track_info" | grep -i "AC-3" | head -1 | cut -d ':' -f 1)

    if [[ -n "$lossless" && -n "$ac3" && "$lossless" != "$ac3" ]]; then
        AUDIO_OPTS="-a ${lossless},${ac3} -E copy"
    elif [[ -n "$lossless" ]]; then
        AUDIO_OPTS="-a ${lossless} -E copy"
    elif [[ -n "$ac3" ]]; then
        AUDIO_OPTS="-a ${ac3} -E copy"
    else
        AUDIO_OPTS="-a 1 -E copy"
    fi
}

build_encoder_options() {
    local infile="$1"

    detect_resolution "$infile"
    lookup_bitrate "$SRC_HEIGHT" "$ANIME"
    detect_audio_tracks "$infile"
    detect_threads

    OPTIONS="--crop 0:0:0:0 --auto-anamorphic --markers"
    OPTIONS="$OPTIONS $AUDIO_OPTS"
    OPTIONS="$OPTIONS --native-language eng --subtitle scan,1,2,3,4,5,6,7,8,9,10 --subtitle-default scan --subtitle-forced scan"

    if [[ $SRC_HEIGHT -ge 2160 ]]; then
        CODEC_TAG="x265"
        local tune_opt=""
        if [[ "$ANIME" == "1" ]]; then
            tune_opt="--encoder-tune animation"
        fi

        OPTIONS="$OPTIONS --encoder x265_10bit --encoder-profile main10 --encoder-level 5.1"
        OPTIONS="$OPTIONS -q 16 --encoder-preset veryslow $tune_opt"
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

    if [[ -z "$out_duration" || "$out_duration" == "0" ]]; then
        echo "ERROR: Output file has no valid duration" >&2
        return 1
    fi

    local diff=$(( src_duration - out_duration ))
    # absolute value
    if [[ $diff -lt 0 ]]; then
        diff=$(( -diff ))
    fi
    local tolerance=$(( src_duration / 20 ))
    if [[ $diff -gt $tolerance ]]; then
        echo "WARNING: Duration mismatch — source: ${src_duration}ms, output: ${out_duration}ms" >&2
        return 1
    fi

    return 0
}

encode_file() {
    local infile="$1"
    local infile_abs
    infile_abs="$(cd "$(dirname "$infile")" && pwd)/$(basename "$infile")"
    local src_dir
    src_dir="$(dirname "$infile_abs")"
    local file_basename
    file_basename="$(basename "$infile_abs")"
    local stem="${file_basename%.*}"

    build_encoder_options "$infile_abs"

    local work_infile="$infile_abs"
    local outfile="${src_dir}/${stem}-${CODEC_TAG}.mkv"
    local logfile="${LOGDIR}/encode-${stem}.log"
    local used_encode_dir=0

    if [[ -n "$ENCODE_DIR" ]]; then
        used_encode_dir=1
        echo "Copying to encode directory: ${ENCODE_DIR}/"
        cp "$infile_abs" "${ENCODE_DIR}/"
        work_infile="${ENCODE_DIR}/${file_basename}"
        outfile="${ENCODE_DIR}/${stem}-${CODEC_TAG}.mkv"
    fi

    echo "Encoding: $file_basename (${SRC_WIDTH}x${SRC_HEIGHT}, ${CODEC_TAG}, bitrate=${BITRATE}, buffer=${BUFFER})"
    echo "Log: $logfile"

    set +e
    # shellcheck disable=SC2086
    $HANDBRAKE $OPTIONS --input "$work_infile" --output "$outfile" > "$logfile" 2>&1
    local rc=$?
    set -e

    if [[ $rc -eq 0 ]] && validate_output "$work_infile" "$outfile"; then
        if [[ $used_encode_dir -eq 1 ]]; then
            mv "$outfile" "${src_dir}/"
            rm -f "$work_infile"
            outfile="${src_dir}/${stem}-${CODEC_TAG}.mkv"
        fi
        rm -f "$infile_abs"
        echo "SUCCESS: $outfile"
    else
        echo "ENCODE FAILED: keeping original — $infile_abs" >&2
        if [[ $used_encode_dir -eq 1 ]]; then
            rm -f "$work_infile" "$outfile"
        else
            rm -f "$outfile"
        fi
        return 1
    fi
}

wait_for_queue() {
    if [[ -f "$PID_FILE" ]]; then
        local pid
        pid=$(cat "$PID_FILE")
        while kill -0 "$pid" 2>/dev/null; do
            echo "Another encode is running (PID $pid). Waiting..."
            sleep 30
        done
    fi
    echo $$ > "$PID_FILE"
}

cleanup_pid() {
    rm -f "$PID_FILE"
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

main() {
    check_deps

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
            h|*) usage ;;
        esac
    done

    if [[ -z "$INFILE" && -z "$DIR" ]]; then
        usage
    fi

    if [[ -n "$ENCODE_DIR" && ! -d "$ENCODE_DIR" ]]; then
        echo "ERROR: Encode directory does not exist: $ENCODE_DIR" >&2
        exit 1
    fi

    if [[ -n "$INFILE" && ! -f "$INFILE" ]]; then
        echo "ERROR: File not found: $INFILE" >&2
        exit 1
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

        screen -S "encoding" -dm bash -c "$(printf '%q' "$script_path")$relaunch_args"
        echo "Encode launched in screen session 'encoding'."
        echo "Attach with: screen -r encoding"
        exit 0
    fi

    trap cleanup_pid EXIT

    if [[ -n "$DIR" ]]; then
        find "$DIR" -type f -iname '*.mkv' | while read -r file; do
            wait_for_queue
            echo "--- Processing: $file ---"
            encode_file "$file" || echo "Skipping failed file: $file"
        done
    elif [[ -n "$INFILE" ]]; then
        wait_for_queue
        encode_file "$INFILE"
    fi
}

main "$@"
