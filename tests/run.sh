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
case ${1#--Inform=} in
    'Video;%Width%'*) echo 3840 ;;
    'Video;%Height%'*) echo 2160 ;;
    'Audio;'*) cat "$STUB_AUDIO/$(basename "$2")" 2>/dev/null || echo '1:AC-3:en' ;;
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
    printf '#!/bin/sh\nexit 0\n' > "$work/bin/screen"
    chmod +x "$work/bin/"*
}

reset() {
    rm -rf "${work:?}/lib" "$work/scratch" "$work/tmp" "$work/audio"
    mkdir -p "$work/lib" "$work/scratch" "$work/tmp" "$work/audio"
    : > "$work/calls"
}

# Run encode.sh in its own process group; kill the group after 10 s.
run_encode() {
    set -m
    TMPDIR="$work/tmp" PATH="$work/bin:$PATH" STUB_LOG="$work/calls" \
        STUB_AUDIO="$work/audio" "$script" "$@" > "$work/out" 2>&1 < /dev/null &
    local pid=$! ticks=0
    set +m
    while kill -0 "$pid" 2>/dev/null; do
        if [[ $ticks -ge 50 ]]; then
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
    if bash -n "$script" && shellcheck "$script" "$repo/tests/run.sh"; then
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
    touch "$work/lib/dual.mkv" "$work/lib/multi.mkv"
    printf '1:E-AC-3:hi\n2:MLP FBA:en\n' > "$work/audio/dual.mkv"
    printf '1:DTS:hi\n2:DTS:en\n3:AC-3:hi\n4:AC-3:en\n' > "$work/audio/multi.mkv"
    run_encode --_internal -e "$work/scratch" -f "$work/lib/dual.mkv" || true
    run_encode --_internal -e "$work/scratch" -f "$work/lib/multi.mkv" || true
    if sed -n 1p "$work/calls" | grep -q -- '-a 2 -E copy' \
          && sed -n 2p "$work/calls" | grep -q -- '-a 2,4 -E copy'; then
        info "audio keeps English lossless and same-language AC-3"
    else err "audio selection: $(cut -c1-120 "$work/calls" | grep -o -- '-a [0-9,]*' | tr '\n' ' ')"; fi
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

make_stubs
for check in test_static test_usage test_directory test_audio test_stale_lock; do
    start=$SECONDS
    "$check"
    echo "    ($((SECONDS - start)) s)"
done
[[ $failures -eq 0 ]] || { echo "$failures check(s) failed" >&2; exit 1; }
