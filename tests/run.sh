#!/bin/bash
# Gate: syntax, shellcheck, then encode.sh against stubbed encoder tools.
set -euo pipefail

repo=$(cd "$(dirname "$0")/.." && pwd)
script=${ENCODE_SCRIPT:-$repo/encode.sh}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0

info(){ echo "  ✓ $*"; }
err(){  echo "  ✗ $*" >&2; failures=$((failures + 1)); }

make_stubs() {
    mkdir -p "$work/bin"
    cat > "$work/bin/mediainfo" <<'EOF'
#!/bin/bash
# File names select variants: *1080* is 1080p, a *short* output is half length.
name=$(basename "$2")
case ${1#--Inform=}:$name in
    'Video;%Width%'*:*1080*) echo 1920 ;;
    'Video;%Height%'*:*1080*) echo 1080 ;;
    'Video;%Width%'*) echo 3840 ;;
    'Video;%Height%'*) echo 2160 ;;
    'Audio;'*) cat "$STUB_AUDIO/$name" 2>/dev/null || echo '1:AC-3:en' ;;
    'Video;%HDR_Format%'*:encode-dvprobe*) cat "$STUB_META/probe.hdr" 2>/dev/null || true ;;
    'Video;%HDR_Format%'*) cat "$STUB_META/$name.hdr" 2>/dev/null || true ;;
    'Text;'*) cat "$STUB_META/$name.subs" 2>/dev/null || true ;;
    'General;%Duration%'*:*short-x26*) echo 500 ;;
    'General;%Duration%'*) echo 1000 ;;
esac
EOF
    # The real CLI reads stdin for key commands (HandBrake test/test.c).
    cat > "$work/bin/HandBrakeCLI" <<'EOF'
#!/bin/bash
printf '%s\n' "$*" >> "$STUB_LOG"
while [ $# -gt 0 ]; do
    case $1 in --input) in=$2; shift ;; --output) out=$2; shift ;; esac
    shift
done
cat > /dev/null
case ${in##*/} in *fail*) exit 1 ;; esac
printf x > "$out"
EOF
    cat > "$work/bin/mkvpropedit" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$MKV_LOG"
EOF
    # screen -S NAME -dm CMD…: run the worker in the foreground.
    cat > "$work/bin/screen" <<'EOF'
#!/bin/sh
shift 3
exec "$@"
EOF
    cat > "$work/bin/wrap" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$WRAP_LOG"
shift
exec "$@"
EOF
    chmod +x "$work/bin/"*
}

reset() {
    rm -rf "${work:?}/lib" "$work/scratch" "$work/tmp" "$work/audio" "$work/meta"
    mkdir -p "$work/lib" "$work/scratch" "$work/tmp" "$work/audio" "$work/meta"
    : > "$work/calls"
    : > "$work/mkv"
    rm -f "$work/hdr-out" "$work/dv-out"
}

# Run encode.sh in its own process group; kill the group after 10 s, or
# after $max_ticks fifths of a second when the caller sets it.
run_encode() {
    set -m
    TMPDIR="$work/tmp" PATH="$work/bin:$PATH" STUB_LOG="$work/calls" \
        STUB_AUDIO="$work/audio" \
        STUB_META="$work/meta" MKV_LOG="$work/mkv" "$script" "$@" > "$work/out" 2>&1 < /dev/null &
    local pid=$! ticks=0
    set +m
    while kill -0 "$pid" 2>/dev/null; do
        if [[ $ticks -ge ${max_ticks:-50} ]]; then
            kill -TERM -- "-$pid" 2>/dev/null || true
            wait "$pid" 2>/dev/null || true
            return 124
        fi
        sleep 0.2
        ticks=$((ticks + 1))
    done
    wait "$pid"
}

test_static() {
    command -v shellcheck > /dev/null || { err "shellcheck is not installed"; return; }
    if bash -n "$script" && bash -n "$repo/tests/run.sh" \
            && shellcheck "$script" "$repo/tests/run.sh"; then
        info "bash -n and shellcheck are clean"
    else err "bash -n or shellcheck failed"; fi
}

test_usage() {
    reset
    local rc=0
    run_encode || rc=$?
    if [[ $rc -eq 0 ]] && grep -q Usage "$work/out"; then
        info "a bare command prints usage and exits 0"
    else err "bare command exited $rc"; fi
}

test_directory() {
    reset
    touch "$work/lib/a.mkv" "$work/lib/b-fail.mkv" "$work/lib/old-x265.mkv"
    local rc=0
    run_encode --_internal -e "$work/scratch" -d "$work/lib" || rc=$?
    if [[ $rc -eq 1 && $(wc -l < "$work/calls") -eq 2 && -f "$work/lib/a-x265.mkv" \
          && ! -e "$work/lib/a.mkv" && -f "$work/lib/b-fail.mkv" \
          && ! -e "$work/lib/b-fail-x265.mkv" && -f "$work/lib/old-x265.mkv" \
          && -z "$(ls -A "$work/scratch")" ]]; then
        info "directory mode encodes each source once, keeps failures, skips outputs"
    else err "directory mode: exit $rc, $(wc -l < "$work/calls" | tr -d ' ') encodes"; fi
}

test_audio() {
    reset
    touch "$work/lib/dual.mkv" "$work/lib/multi.mkv" "$work/lib/untagged.mkv" \
        "$work/lib/foreign.mkv"
    printf '1:E-AC-3:hi\n2:MLP FBA:en\n' > "$work/audio/dual.mkv"
    printf '1:DTS:hi\n2:DTS:en\n3:AC-3:hi\n4:AC-3:en\n' > "$work/audio/multi.mkv"
    printf '1:DTS:\n2:AC-3:fr\n3:AC-3:en\n' > "$work/audio/untagged.mkv"
    printf '1:DTS:\n2:AC-3:fr\n' > "$work/audio/foreign.mkv"
    local name
    for name in dual multi untagged foreign; do
        run_encode --_internal -e "$work/scratch" -f "$work/lib/$name.mkv" || true
    done
    if sed -n 1p "$work/calls" | grep -q -- '-a 2 -E copy' \
          && sed -n 2p "$work/calls" | grep -q -- '-a 2,4 -E copy' \
          && sed -n 3p "$work/calls" | grep -q -- '-a 1,3 -E copy' \
          && sed -n 4p "$work/calls" | grep -q -- '-a 1,2 -E copy'; then
        info "audio keeps English lossless and same-language AC-3, English first when untagged"
    else err "audio selection: $(cut -c1-120 "$work/calls" | grep -o -- '-a [0-9,]*' | tr '\n' ' ')"; fi
}

test_x264_tier() {
    reset
    touch "$work/lib/hd1080.mkv"
    local rc=0
    run_encode --_internal -e "$work/scratch" -f "$work/lib/hd1080.mkv" || rc=$?
    if [[ $rc -eq 0 && -f "$work/lib/hd1080-x264.mkv" && ! -e "$work/lib/hd1080.mkv" \
          && $(wc -l < "$work/calls") -eq 1 ]] \
          && grep -q -- '--encoder x264 .*:bitrate=14020:vbv-maxrate=30000:.* --vb 14020' "$work/calls" \
          && ! grep -q x265 "$work/calls"; then
        info "a 1080p source encodes with x264 at the 1080p bitrate"
    else err "x264 tier: exit $rc, $(grep -o -- '--encoder [a-z0-9_]*\|bitrate=[0-9]*' "$work/calls" | tr '\n' ' ')"; fi
}

test_duration() {
    reset
    touch "$work/lib/short.mkv"
    local rc=0
    run_encode --_internal -e "$work/scratch" -f "$work/lib/short.mkv" || rc=$?
    if [[ $rc -eq 1 && $(wc -l < "$work/calls") -eq 1 && -f "$work/lib/short.mkv" \
          && ! -e "$work/lib/short-x265.mkv" && -z "$(ls -A "$work/scratch")" ]] \
          && grep -q 'Duration mismatch' "$work/out"; then
        info "an output of the wrong duration is removed and the source kept"
    else err "duration mismatch: exit $rc, kept: $(cd "$work/lib" && echo *)"; fi
}

# Source flags are copied in order; a scan hit shifts them by one track.
test_subtitle_flags() {
    reset
    touch "$work/lib/forced.mkv" "$work/lib/scanhit.mkv" "$work/lib/lost.mkv"
    printf 'Yes:Yes\nNo:No\nNo:No\n' > "$work/meta/forced.mkv.subs"
    printf 'No:No\nNo:No\nNo:No\n' > "$work/meta/forced-x265.mkv.subs"
    printf 'Yes:Yes\nNo:No\n' > "$work/meta/scanhit.mkv.subs"
    printf 'No:No\nNo:No\nNo:No\n' > "$work/meta/scanhit-x265.mkv.subs"
    printf 'Yes:Yes\nNo:No\nNo:No\n' > "$work/meta/lost.mkv.subs"
    printf 'No:No\n' > "$work/meta/lost-x265.mkv.subs"
    local rc_forced=0 rc_scan=0 rc_lost=0 name
    for name in forced scanhit lost; do
        local rc=0
        run_encode --_internal -e "$work/scratch" -f "$work/lib/$name.mkv" || rc=$?
        eval "rc_${name%hit}=$rc"
    done
    local s1='track:s1 --set flag-default=1 --set flag-forced=1'
    local plain='--set flag-default=0 --set flag-forced=0'
    if [[ $rc_forced -eq 0 && $rc_scan -eq 0 && $rc_lost -eq 1 \
            && $(wc -l < "$work/mkv") -eq 2 \
            && $(sed -n 1p "$work/mkv") == *"forced-x265.mkv --edit $s1 --edit track:s2 $plain --edit track:s3 $plain" \
            && $(sed -n 2p "$work/mkv") == *"scanhit-x265.mkv --edit $s1 --edit track:s2 --set flag-default=1 --set flag-forced=1 --edit track:s3 $plain" \
            && ! -e "$work/lib/forced.mkv" && -f "$work/lib/lost.mkv" \
            && ! -e "$work/lib/lost-x265.mkv" ]] \
            && grep -q 'source has 3, output has 1' "$work/out"; then
        info "subtitle flags copy in order, shift after a scan hit, and a count mismatch keeps the source"
    else err "subtitle flags: exits $rc_forced/$rc_scan/$rc_lost; $(tr '\n' '|' < "$work/mkv")"; fi
}

# An output that lost Dolby Vision or HDR10 is removed and the source kept.
test_hdr_guard() {
    reset
    touch "$work/lib/dv.mkv" "$work/lib/hdr10.mkv" "$work/lib/kept.mkv" "$work/lib/sdr.mkv"
    echo 'Dolby Vision / SMPTE ST 2086' > "$work/meta/dv.mkv.hdr"
    echo 'SMPTE ST 2086' > "$work/meta/dv-x265.mkv.hdr"
    echo 'SMPTE ST 2086' > "$work/meta/hdr10.mkv.hdr"
    echo 'Dolby Vision / SMPTE ST 2086' > "$work/meta/kept.mkv.hdr"
    echo 'Dolby Vision / SMPTE ST 2086 / SMPTE ST 2086' > "$work/meta/kept-x265.mkv.hdr"
    echo 'Dolby Vision / SMPTE ST 2086' > "$work/meta/probe.hdr"
    local rc_dv=0 rc_hdr10=0 rc_kept=0 rc_sdr=0 name
    for name in dv hdr10 kept sdr; do
        local rc=0
        run_encode --_internal -e "$work/scratch" -f "$work/lib/$name.mkv" || rc=$?
        eval "rc_$name=$rc"
        cat "$work/out" >> "$work/hdr-out"
    done
    if [[ $rc_dv -eq 1 && $rc_hdr10 -eq 1 && $rc_kept -eq 0 && $rc_sdr -eq 0 \
            && -f "$work/lib/dv.mkv" && ! -e "$work/lib/dv-x265.mkv" \
            && -f "$work/lib/hdr10.mkv" && ! -e "$work/lib/hdr10-x265.mkv" \
            && ! -e "$work/lib/kept.mkv" && -f "$work/lib/kept-x265.mkv" \
            && ! -e "$work/lib/sdr.mkv" && -z "$(ls -A "$work/scratch")" ]] \
            && grep -q "lacks the source's Dolby Vision" "$work/hdr-out" \
            && grep -q 'libdovi' "$work/hdr-out"; then
        info "an output that lost Dolby Vision or HDR10 keeps the source"
    else err "hdr guard: exits $rc_dv/$rc_hdr10/$rc_kept/$rc_sdr"; fi
}

# A HandBrakeCLI that drops Dolby Vision fails before the encode, unless
# ENCODE_ALLOW_DV_LOSS=1 turns it into a warning.
test_dv_probe() {
    reset
    touch "$work/lib/nodv.mkv" "$work/lib/allow.mkv" "$work/lib/launch.mkv"
    local name
    for name in nodv allow launch; do
        echo 'Dolby Vision / SMPTE ST 2086' > "$work/meta/$name.mkv.hdr"
    done
    echo 'SMPTE ST 2086' > "$work/meta/allow-x265.mkv.hdr"
    local rc_nodv=0 rc_allow=0 rc_launch=0 calls_nodv calls_launch
    run_encode --_internal -e "$work/scratch" -f "$work/lib/nodv.mkv" || rc_nodv=$?
    calls_nodv=$(wc -l < "$work/calls")
    cat "$work/out" > "$work/dv-out"
    ENCODE_ALLOW_DV_LOSS=1 run_encode --_internal -e "$work/scratch" \
        -f "$work/lib/allow.mkv" || rc_allow=$?
    cat "$work/out" >> "$work/dv-out"
    : > "$work/calls"
    run_encode -e "$work/scratch" -f "$work/lib/launch.mkv" || rc_launch=$?
    calls_launch=$(wc -l < "$work/calls")
    if [[ $rc_nodv -eq 1 && $calls_nodv -eq 1 && $rc_allow -eq 0 \
            && $rc_launch -eq 1 && $calls_launch -eq 1 \
            && -f "$work/lib/nodv.mkv" && -f "$work/lib/launch.mkv" \
            && ! -e "$work/lib/allow.mkv" && -f "$work/lib/allow-x265.mkv" ]] \
            && grep -q -- '--stop-at seconds:2' "$work/calls" \
            && grep -q 'drops Dolby Vision; keeping' "$work/dv-out" \
            && grep -q 'WARNING: .*HDR10 only' "$work/dv-out" \
            && ! grep -q 'Encode launched' "$work/out"; then
        info "a HandBrakeCLI that drops Dolby Vision stops before encoding, or warns when allowed"
    else err "dv probe: exits $rc_nodv/$rc_allow/$rc_launch, calls $calls_nodv/$calls_launch"; fi
}

test_stale_lock() {
    reset
    touch "$work/lib/a.mkv"
    mkdir "$work/tmp/encode.lock"
    echo 999999 > "$work/tmp/encode.lock/pid"
    local rc=0
    run_encode --_internal -e "$work/scratch" -f "$work/lib/a.mkv" || rc=$?
    if [[ $rc -eq 0 && -f "$work/lib/a-x265.mkv" && ! -e "$work/tmp/encode.lock" ]]; then
        info "a dead holder's lock is reclaimed and released"
    else err "stale lock: exit $rc"; fi
}

test_scratch_alias() {
    reset
    touch "$work/lib/a.mkv" "$work/lib/b-fail.mkv"
    ln -s "$work/lib" "$work/scratch/alias"
    local ok=0 failed=0
    run_encode --_internal -e "$work/scratch/alias" -f "$work/lib/a.mkv" || ok=$?
    run_encode --_internal -e "$work/scratch/alias" -f "$work/lib/b-fail.mkv" || failed=$?
    if [[ $ok -eq 0 && -f "$work/lib/a-x265.mkv" && ! -e "$work/lib/a.mkv" \
          && $failed -eq 1 && -f "$work/lib/b-fail.mkv" ]]; then
        info "a scratch path that is the source directory encodes in place"
    else err "scratch alias: exits $ok and $failed, kept: $(cd "$work/lib" && echo *)"; fi
}

test_orphan_lock() {
    reset
    touch "$work/lib/a.mkv"
    mkdir "$work/tmp/encode.lock"
    local rc=0
    run_encode --_internal -e "$work/scratch" -f "$work/lib/a.mkv" || rc=$?
    if [[ $rc -eq 0 && -f "$work/lib/a-x265.mkv" && ! -e "$work/tmp/encode.lock" ]]; then
        info "a lock left without a holder's marker is reclaimed"
    else err "orphan lock: exit $rc"; fi
}

test_nested_orphan() {
    reset
    touch "$work/lib/a.mkv"
    mkdir -p "$work/tmp/encode.lock/encode.lock.999999"
    : > "$work/tmp/encode.lock/encode.lock.999999/pid.999999"
    local rc=0
    run_encode --_internal -e "$work/scratch" -f "$work/lib/a.mkv" || rc=$?
    if [[ $rc -eq 0 && $(wc -l < "$work/calls") -eq 1 && -f "$work/lib/a-x265.mkv" \
          && ! -e "$work/tmp/encode.lock" ]]; then
        info "a dead publisher's directory stranded in the lock is cleared"
    else err "nested orphan: exit $rc"; fi
}

# A stub plays a second waiter that wins between this run's read of the dead
# pid and its takeover; the run must then wait, not displace the new holder.
lock_race() {
    local tool=$1 marker=$2 rc=0 max_ticks=10
    reset
    touch "$work/lib/a.mkv"
    mkdir "$work/tmp/encode.lock"
    echo 999999 > "$work/tmp/encode.lock/$marker"
    cat > "$work/bin/$tool" <<EOF
#!/bin/bash
real=$(command -v "$tool")
if [[ \${*: -1} == */encode.lock/$marker && $tool == cat && ! -e "$work/raced" ]]; then
    : > "$work/raced"
    "\$real" "\$@"
    mv "\${*: -1}" "$work/tmp/encode.lock/pid.$$"
elif [[ \${*: -2:1} == */encode.lock/$marker && $tool == mv ]]; then
    : > "$work/raced"
    "\$real" "\${*: -2:1}" "$work/tmp/encode.lock/pid.$$"
    "\$real" "\$@"
else
    "\$real" "\$@"
fi
EOF
    chmod +x "$work/bin/$tool"
    run_encode --_internal -e "$work/scratch" -f "$work/lib/a.mkv" || rc=$?
    rm -f "$work/bin/$tool"
    [[ $rc -eq 124 && -e "$work/raced" && ! -s "$work/calls" && -f "$work/lib/a.mkv" \
        && -e "$work/tmp/encode.lock/pid.$$" ]]
}

test_lock_race() {
    if lock_race cat pid && lock_race mv pid.999999; then
        info "a waiter that saw a dead pid leaves a newer holder's lock alone"
    else err "lock race: $(wc -l < "$work/calls" | tr -d ' ') encodes beside a live holder"; fi
}

# exec keeps the PID, so the lock names the very process that then waits.
test_own_pid_lock() {
    reset
    touch "$work/lib/a.mkv"
    cat > "$work/bin/relock" <<'EOF'
#!/bin/bash
mkdir "$TMPDIR/encode.lock"
echo $$ > "$TMPDIR/encode.lock/pid"
exec "$RELOCK_SCRIPT" "$@"
EOF
    chmod +x "$work/bin/relock"
    export RELOCK_SCRIPT=$script
    local rc=0 script="$work/bin/relock"
    run_encode --_internal -e "$work/scratch" -f "$work/lib/a.mkv" || rc=$?
    if [[ $rc -eq 0 && -f "$work/lib/a-x265.mkv" && ! -e "$work/tmp/encode.lock" ]]; then
        info "a dead holder's lock that names this run's reused PID is reclaimed"
    else err "own-pid lock: exit $rc"; fi
}

# The launcher runs the worker under ENCODE_WRAPPER's words, else directly.
test_wrapper() {
    reset
    touch "$work/lib/a.mkv" "$work/lib/b.mkv"
    local wrapped=0 plain=0
    WRAP_LOG="$work/wrap" ENCODE_WRAPPER="$work/bin/wrap --lease" \
        run_encode -e "$work/scratch" -f "$work/lib/a.mkv" || wrapped=$?
    WRAP_LOG="$work/wrap" run_encode -e "$work/scratch" -f "$work/lib/b.mkv" || plain=$?
    local log
    log=$(cat "$work/wrap" 2>/dev/null) || true
    if [[ $wrapped -eq 0 && $plain -eq 0 && -f "$work/lib/a-x265.mkv" \
            && -f "$work/lib/b-x265.mkv" \
            && $log == "--lease $script --_internal -e $work/scratch -f $work/lib/a.mkv" ]]; then
        info "ENCODE_WRAPPER wraps the detached worker; unset, the worker runs bare"
    else err "wrapper: exits $wrapped/$plain, log '$log'"; fi
}

make_stubs
for check in test_static test_usage test_directory test_audio test_x264_tier \
        test_duration test_subtitle_flags test_hdr_guard test_dv_probe \
        test_stale_lock \
        test_scratch_alias test_orphan_lock test_nested_orphan test_lock_race \
        test_own_pid_lock test_wrapper; do
    start=$SECONDS
    "$check"
    echo "    ($((SECONDS - start)) s)"
done
[[ $failures -eq 0 ]] || { echo "$failures check(s) failed" >&2; exit 1; }
