#!/bin/sh

set -eu

usage() {
    cat <<'EOF'
usage: tools/verify.sh [quick|full]

quick  Run bounded format, documentation-policy, package, and interop gates.
full   Add the broad native ReleaseSafe and Python suites plus optional Rust.
EOF
}

profile=quick
case "$#" in
    0) ;;
    1)
        case "$1" in
            quick | full)
                profile=$1
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            *)
                usage >&2
                exit 64
                ;;
        esac
        ;;
    *)
        usage >&2
        exit 64
        ;;
esac

script_dir=$(
    CDPATH= cd "$(dirname "$0")" 2>/dev/null &&
        pwd -P
) || {
    echo "FAIL  verifier/root: cannot resolve the tools directory" >&2
    exit 1
}
repository_root=$(
    CDPATH= cd "$script_dir/.." 2>/dev/null &&
        pwd -P
) || {
    echo "FAIL  verifier/root: cannot resolve the repository root" >&2
    exit 1
}
cd "$repository_root" || {
    echo "FAIL  verifier/root: cannot enter the repository root" >&2
    exit 1
}

cache_parent=${TMPDIR:-/tmp}
case "$cache_parent" in
    /*) ;;
    *)
        echo "FAIL  verifier/cache: TMPDIR must be an absolute path" >&2
        exit 1
        ;;
esac
cache_parent=$(
    CDPATH= cd "$cache_parent" 2>/dev/null &&
        pwd -P
) || {
    echo "FAIL  verifier/cache: TMPDIR must name an existing directory" >&2
    exit 1
}
if [ "$cache_parent" = "/" ]; then
    echo "FAIL  verifier/cache: TMPDIR must not be the filesystem root" >&2
    exit 1
fi

verification_root=$(mktemp -d "$cache_parent/glacier-verify.XXXXXX") || {
    echo "FAIL  verifier/cache: cannot create temporary workspace" >&2
    exit 1
}

cleanup_verification() {
    case "$verification_root" in
        "$cache_parent"/glacier-verify.*)
            if [ -d "$verification_root" ]; then
                verification_size=$(
                    du -sh "$verification_root" 2>/dev/null |
                        awk '{print $1}'
                ) || verification_size=unknown
                echo "temporary verification data: $verification_size; removing $verification_root"
                rm -rf -- "$verification_root"
            fi
            ;;
        *)
            echo "refusing to remove unexpected verification path: $verification_root" >&2
            return 1
            ;;
    esac
}

trap cleanup_verification EXIT

chmod 700 "$verification_root" || {
    echo "FAIL  verifier/cache: cannot protect temporary workspace" >&2
    exit 1
}
mkdir "$verification_root/logs" || {
    echo "FAIL  verifier/cache: cannot create temporary log directory" >&2
    exit 1
}

ZIG_LOCAL_CACHE_DIR="$verification_root/zig-local"
ZIG_GLOBAL_CACHE_DIR="$verification_root/zig-global"
verification_prefix="$verification_root/prefix"
PYTHONDONTWRITEBYTECODE=1
export ZIG_LOCAL_CACHE_DIR ZIG_GLOBAL_CACHE_DIR PYTHONDONTWRITEBYTECODE

active_pid=

terminate_verification() {
    signal_name=$1
    exit_status=$2
    trap - HUP INT TERM
    if [ -n "$active_pid" ] && kill -0 "$active_pid" 2>/dev/null; then
        kill "-$signal_name" "$active_pid" 2>/dev/null || true
        wait "$active_pid" 2>/dev/null || true
    fi
    exit "$exit_status"
}

trap 'terminate_verification HUP 129' HUP
trap 'terminate_verification INT 130' INT
trap 'terminate_verification TERM 143' TERM

pass_count=0
skip_count=0
fail_count=0

record_pass() {
    pass_count=$((pass_count + 1))
    printf 'PASS  %s: %s\n' "$1" "$2"
}

record_skip() {
    skip_count=$((skip_count + 1))
    printf 'SKIP  %s: %s\n' "$1" "$2"
}

record_fail() {
    fail_count=$((fail_count + 1))
    printf 'FAIL  %s: %s\n' "$1" "$2"
}

run_gate() {
    gate_name=$1
    shift
    gate_slug=$(
        printf '%s' "$gate_name" |
            tr -c 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-' '_'
    )
    gate_log="$verification_root/logs/$gate_slug.log"
    gate_started=$(date +%s)

    "$@" >"$gate_log" 2>&1 &
    active_pid=$!
    if wait "$active_pid"; then
        gate_status=0
    else
        gate_status=$?
    fi
    active_pid=

    gate_finished=$(date +%s)
    gate_elapsed=$((gate_finished - gate_started))
    if [ "$gate_status" -eq 0 ]; then
        record_pass "$gate_name" "${gate_elapsed}s"
    else
        record_fail "$gate_name" "exit $gate_status after ${gate_elapsed}s"
        if [ -s "$gate_log" ]; then
            sed 's/^/      /' "$gate_log"
        fi
    fi
}

run_zig_build() {
    zig build "$@" \
        -Doptimize=ReleaseSafe \
        -Dmetal=false \
        -j2 \
        --cache-dir "$ZIG_LOCAL_CACHE_DIR" \
        --global-cache-dir "$ZIG_GLOBAL_CACHE_DIR" \
        --prefix "$verification_prefix"
}

printf 'Glacier local verification (%s)\n' "$profile"
printf 'Temporary workspace: %s\n' "$verification_root"

has_zig=0
if command -v zig >/dev/null 2>&1; then
    if zig_version=$(zig version 2>/dev/null); then
        has_zig=1
        record_pass "toolchain/zig" "$zig_version"
    else
        record_fail "toolchain/zig" "zig version failed"
    fi
else
    record_fail "toolchain/zig" "zig is not on PATH"
fi

has_python=0
if command -v python3 >/dev/null 2>&1; then
    if python_version=$(python3 --version 2>&1); then
        has_python=1
        record_pass "toolchain/python" "$python_version"
    else
        record_fail "toolchain/python" "python3 --version failed"
    fi
else
    record_fail "toolchain/python" "python3 is not on PATH"
fi

if [ "$has_zig" -eq 1 ]; then
    run_gate "format/zig" \
        zig fmt --check build.zig src bench examples tests
else
    record_skip "format/zig" "requires a working zig executable"
fi

if [ "$has_python" -eq 1 ]; then
    run_gate "policy/public-markdown" \
        python3 -m unittest bench.tests.test_public_markdown_policy
else
    record_skip "policy/public-markdown" "requires a working python3 executable"
fi

if [ "$has_zig" -eq 1 ] && [ "$has_python" -eq 1 ]; then
    run_gate "interop/c-cpp-python" \
        run_zig_build contract-interop-test
else
    record_skip "interop/c-cpp-python" "requires both zig and python3"
fi

if [ "$has_zig" -eq 1 ]; then
    run_gate "package/modules" \
        run_zig_build package-module-test
else
    record_skip "package/modules" "requires a working zig executable"
fi

if [ "$profile" = "full" ]; then
    if [ "$has_zig" -eq 1 ]; then
        run_gate "native/releasesafe-suite" \
            run_zig_build test
    else
        record_skip "native/releasesafe-suite" "requires a working zig executable"
    fi

    if [ "$has_python" -eq 1 ]; then
        run_gate "python/full-suite" \
            python3 -m unittest discover -s bench/tests
    else
        record_skip "python/full-suite" "requires a working python3 executable"
    fi

    host_name=$(uname -s 2>/dev/null || printf unknown)
    case "$host_name" in
        Darwin | Linux | FreeBSD)
            if command -v rustc >/dev/null 2>&1; then
                if [ "$has_zig" -eq 1 ]; then
                    run_gate "interop/rust" \
                        run_zig_build contract-rust-test
                else
                    record_skip "interop/rust" "requires a working zig executable"
                fi
            else
                record_skip "interop/rust" "optional rustc is not on PATH"
            fi
            ;;
        *)
            record_skip "interop/rust" "unsupported host for the retained native Rust gate"
            ;;
    esac
else
    record_skip "native/releasesafe-suite" "quick profile; run tools/verify.sh full"
    record_skip "python/full-suite" "quick profile; run tools/verify.sh full"
    record_skip "interop/rust" "quick profile; run tools/verify.sh full"
fi

record_skip "native/debug-releasefast" \
    "change-specific matrix; see docs/CONTRIBUTING.md"
record_skip "concurrency/thread-sanitizer" \
    "run only on a supported host for concurrency changes"
record_skip "portability/cross-target" \
    "run the affected targets from docs/CONTRIBUTING.md"

printf 'Summary: %s PASS, %s SKIP, %s FAIL\n' \
    "$pass_count" "$skip_count" "$fail_count"

if [ "$fail_count" -ne 0 ]; then
    exit 1
fi
exit 0
