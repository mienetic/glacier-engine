#!/bin/sh

set -eu

if [ "$#" -eq 0 ]; then
    echo "usage: tools/zig-with-ephemeral-cache.sh <zig arguments...>" >&2
    echo "example: tools/zig-with-ephemeral-cache.sh build contract-c -Dmetal=false -j2" >&2
    exit 64
fi

for argument in "$@"; do
    case "$argument" in
        --cache-dir | --cache-dir=* | --global-cache-dir | --global-cache-dir=*)
            echo "cache paths are managed by this script" >&2
            exit 64
            ;;
    esac
done

cache_parent=${TMPDIR:-/tmp}
case "$cache_parent" in
    /*) ;;
    *)
        echo "TMPDIR must be an absolute path" >&2
        exit 64
        ;;
esac

cache_parent=$(
    CDPATH= cd "$cache_parent" 2>/dev/null &&
        pwd -P
) || {
    echo "TMPDIR must name an existing directory" >&2
    exit 64
}
if [ "$cache_parent" = "/" ]; then
    echo "TMPDIR must not be the filesystem root" >&2
    exit 64
fi

cache_root=$(mktemp -d "$cache_parent/glacier-zig-cache.XXXXXX")
chmod 700 "$cache_root"
ZIG_LOCAL_CACHE_DIR="$cache_root/local"
ZIG_GLOBAL_CACHE_DIR="$cache_root/global"
export ZIG_LOCAL_CACHE_DIR ZIG_GLOBAL_CACHE_DIR
zig_pid=

cleanup_cache() {
    case "$cache_root" in
        "$cache_parent"/glacier-zig-cache.*)
            if [ -d "$cache_root" ]; then
                cache_size=$(du -sh "$cache_root" 2>/dev/null | awk '{print $1}') ||
                    cache_size=unknown
                echo "ephemeral Zig cache used: $cache_size; removing $cache_root" >&2
                rm -rf -- "$cache_root"
            fi
            ;;
        *)
            echo "refusing to remove unexpected cache path: $cache_root" >&2
            return 1
            ;;
    esac
}

terminate_build() {
    signal_name=$1
    exit_status=$2
    trap - HUP INT TERM
    if [ -n "$zig_pid" ] && kill -0 "$zig_pid" 2>/dev/null; then
        kill "-$signal_name" "$zig_pid" 2>/dev/null || true
        wait "$zig_pid" 2>/dev/null || true
    fi
    exit "$exit_status"
}

trap cleanup_cache EXIT
trap 'terminate_build HUP 129' HUP
trap 'terminate_build INT 130' INT
trap 'terminate_build TERM 143' TERM

zig "$@" \
    --cache-dir "$ZIG_LOCAL_CACHE_DIR" \
    --global-cache-dir "$ZIG_GLOBAL_CACHE_DIR" &
zig_pid=$!
if wait "$zig_pid"; then
    build_status=0
else
    build_status=$?
fi
zig_pid=
exit "$build_status"
