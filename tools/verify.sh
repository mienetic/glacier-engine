#!/bin/sh

set -eu

usage() {
    cat <<'EOF'
usage: tools/verify.sh [quick|full|matrix]
       tools/verify.sh affected --base REV
       GLACIER_VERIFY_BASE=REV tools/verify.sh affected
       GLACIER_VERIFY_REQUIRE_NATIVE=1 tools/verify.sh affected --base REV

quick  Run bounded format, documentation-policy, package, and interop gates.
full   Add the broad native ReleaseSafe and Python suites plus optional Rust.
affected
       Select the union of host and cross-target gates for every path changed
       since the merge base with REV. --base overrides GLACIER_VERIFY_BASE.
matrix Run full host gates plus every retained cross-target compile gate.
EOF
}

profile=quick
base_ref=${GLACIER_VERIFY_BASE:-}
case "$#" in
    0) ;;
    1)
        case "$1" in
            quick | full | matrix)
                profile=$1
                ;;
            affected)
                profile=affected
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
    2)
        case "$1:$2" in
            affected:--base=*)
                profile=affected
                base_ref=${2#--base=}
                ;;
            *)
                usage >&2
                exit 64
                ;;
        esac
        ;;
    3)
        if [ "$1" = "affected" ] && [ "$2" = "--base" ]; then
            profile=affected
            base_ref=$3
        else
            usage >&2
            exit 64
        fi
        ;;
    *)
        usage >&2
        exit 64
        ;;
esac

if [ "$profile" = "affected" ] && [ -z "$base_ref" ]; then
    echo "FAIL  verifier/base: affected requires --base REV or GLACIER_VERIFY_BASE" >&2
    usage >&2
    exit 64
fi

require_native=${GLACIER_VERIFY_REQUIRE_NATIVE:-0}
case "$require_native" in
    0 | 1) ;;
    *)
        echo "FAIL  verifier/native-mode: GLACIER_VERIFY_REQUIRE_NATIVE must be 0 or 1" >&2
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
                echo "removing temporary verification data: $verification_root"
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
affected_paths_file="$verification_root/affected.paths0"
affected_flags_file="$verification_root/affected.flags"
selected_targets_file="$verification_root/selected.targets"
selected_target_steps_file="$verification_root/selected.target-steps"
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
last_gate_status=0

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

    "$@" </dev/null >"$gate_log" 2>&1 &
    active_pid=$!
    if wait "$active_pid"; then
        gate_status=0
    else
        gate_status=$?
    fi
    active_pid=
    last_gate_status=$gate_status

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

run_zig_metal_build() {
    zig build native-metal-observation-test \
        native-metal-correctness-test \
        profile-device-compile \
        profile-host-tool-compile \
        -Dmetal-output-dir="$verification_root/metal" \
        -Doptimize=ReleaseSafe \
        -Dmetal=true \
        -j2 \
        --cache-dir "$ZIG_LOCAL_CACHE_DIR" \
        --global-cache-dir "$ZIG_GLOBAL_CACHE_DIR" \
        --prefix "$verification_root/prefix-metal"
}

run_zig_target_build() {
    target_name=$1
    shift
    zig build "$@" \
        -Dtarget="$target_name" \
        -Doptimize=ReleaseSafe \
        -Dmetal=false \
        -j2 \
        --cache-dir "$ZIG_LOCAL_CACHE_DIR" \
        --global-cache-dir "$ZIG_GLOBAL_CACHE_DIR" \
        --prefix "$verification_root/prefix-$target_name"
}

plan_has() {
    [ -f "$affected_flags_file" ] &&
        grep -Fqx "$1" "$affected_flags_file"
}

run_target_gates() {
    selected_target=$1
    set --
    while IFS=' ' read -r step_target selected_step extra ||
        [ -n "$step_target$selected_step$extra" ]; do
        if [ "$step_target" = "$selected_target" ]; then
            set -- "$@" "$selected_step"
        fi
    done <"$selected_target_steps_file"
    target_gate_label=$(
        printf '%s' "$*" | tr ' ' '+'
    )
    if [ "$has_zig" -eq 1 ]; then
        run_gate "portability/$selected_target/$target_gate_label" \
            run_zig_target_build "$selected_target" "$@"
    else
        record_skip \
            "portability/$selected_target/$target_gate_label" \
            "requires a working zig executable"
    fi
}

record_native_unavailable() {
    if [ "$require_native" -eq 1 ]; then
        record_fail "$1" "$2"
    else
        record_skip "$1" "$2"
    fi
}

run_or_reuse_native_suite() {
    native_gate=$1
    if [ "$native_full_status" = "0" ]; then
        record_pass "$native_gate" \
            "covered by native/releasesafe-suite"
    elif [ "$native_full_status" = "unavailable" ]; then
        record_native_unavailable "$native_gate" \
            "requires a working zig executable"
    elif [ "$native_full_status" != "not-run" ]; then
        record_fail "$native_gate" \
            "covering native/releasesafe-suite failed"
    elif [ "$has_zig" -eq 1 ]; then
        run_gate "$native_gate" run_zig_build test
    else
        record_native_unavailable "$native_gate" \
            "requires a working zig executable"
    fi
}

run_target_plan() {
    selected_target_count=0
    seen_targets="|"
    target_plan_valid=1
    previous_target_rank=0
    if [ ! -f "$selected_targets_file" ]; then
        record_fail "verifier/targets" "selected target plan is unavailable"
        return
    fi
    if [ ! -f "$selected_target_steps_file" ]; then
        record_fail "verifier/target-steps" \
            "selected target-step plan is unavailable"
        return
    fi
    while IFS= read -r selected_target || [ -n "$selected_target" ]; do
        case "$selected_target" in
            "" | -* | *[!ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._+-]*)
                record_fail "verifier/targets" \
                    "policy emitted an invalid target name"
                target_plan_valid=0
                continue
                ;;
        esac
        case "$seen_targets" in
            *"|$selected_target|"*)
                record_fail "verifier/targets" \
                    "policy emitted a duplicate target: $selected_target"
                target_plan_valid=0
                continue
                ;;
        esac
        case "$selected_target" in
            x86_64-linux-musl) target_rank=1 ;;
            aarch64-linux-musl) target_rank=2 ;;
            x86_64-windows-gnu) target_rank=3 ;;
            x86_64-freebsd) target_rank=4 ;;
            *)
                record_fail "verifier/targets" \
                    "policy emitted an unknown target: $selected_target"
                target_plan_valid=0
                continue
                ;;
        esac
        if [ "$target_rank" -le "$previous_target_rank" ]; then
            record_fail "verifier/targets" \
                "policy emitted targets out of retained order: $selected_target"
            target_plan_valid=0
        else
            previous_target_rank=$target_rank
        fi
        seen_targets="${seen_targets}${selected_target}|"
        selected_target_count=$((selected_target_count + 1))
    done <"$selected_targets_file"

    seen_target_steps="|"
    while IFS=' ' read -r step_target selected_step extra ||
        [ -n "$step_target$selected_step$extra" ]; do
        if [ -z "$step_target" ] || [ -z "$selected_step" ] ||
            [ -n "$extra" ]; then
            record_fail "verifier/target-steps" \
                "policy emitted a malformed target-step record"
            target_plan_valid=0
            continue
        fi
        case "$seen_targets" in
            *"|$step_target|"*) ;;
            *)
                record_fail "verifier/target-steps" \
                    "policy emitted a step for an unselected target: $step_target"
                target_plan_valid=0
                continue
                ;;
        esac
        case "$selected_step" in
            install | install-benchmarks | test-compile | profile-core-compile | profile-cpu-compile | profile-durable-compile | profile-device-compile | profile-host-tool-compile | profile-complete-compile) ;;
            *)
                record_fail "verifier/target-steps" \
                    "policy emitted an unknown target step: $selected_step"
                target_plan_valid=0
                continue
                ;;
        esac
        case "$seen_target_steps" in
            *"|$step_target:$selected_step|"*)
                record_fail "verifier/target-steps" \
                    "policy emitted a duplicate target step: $step_target $selected_step"
                target_plan_valid=0
                ;;
            *)
                seen_target_steps="${seen_target_steps}${step_target}:${selected_step}|"
                ;;
        esac
    done <"$selected_target_steps_file"

    while IFS= read -r selected_target || [ -n "$selected_target" ]; do
        selected_step_words=
        previous_profile_rank=0
        selected_step_count=0
        selected_steps_valid=1
        while IFS=' ' read -r step_target selected_step extra ||
            [ -n "$step_target$selected_step$extra" ]; do
            if [ "$step_target" != "$selected_target" ]; then
                continue
            fi
            selected_step_count=$((selected_step_count + 1))
            if [ -z "$selected_step_words" ]; then
                selected_step_words=$selected_step
            else
                selected_step_words="$selected_step_words $selected_step"
            fi
            case "$selected_step" in
                profile-core-compile) profile_rank=1 ;;
                profile-cpu-compile) profile_rank=2 ;;
                profile-durable-compile) profile_rank=3 ;;
                profile-device-compile) profile_rank=4 ;;
                profile-host-tool-compile) profile_rank=5 ;;
                install | install-benchmarks | test-compile | profile-complete-compile) profile_rank=0 ;;
                *) selected_steps_valid=0 ;;
            esac
            if [ "$profile_rank" -gt 0 ]; then
                if [ "$profile_rank" -le "$previous_profile_rank" ]; then
                    selected_steps_valid=0
                fi
                previous_profile_rank=$profile_rank
            fi
        done <"$selected_target_steps_file"
        if [ "$selected_step_count" -eq 0 ]; then
            record_fail "verifier/target-steps" \
                "selected target has no build steps: $selected_target"
            target_plan_valid=0
        elif [ "$selected_step_words" = \
            "install install-benchmarks test-compile" ]; then
            :
        elif [ "$selected_step_words" = \
            "profile-complete-compile" ]; then
            :
        elif [ "$selected_steps_valid" -ne 1 ]; then
            record_fail "verifier/target-steps" \
                "target steps are not a canonical focused profile list: $selected_target"
            target_plan_valid=0
        else
            case "$selected_step_words" in
                *install* | *test-compile* | *profile-complete-compile*)
                    record_fail "verifier/target-steps" \
                        "full target steps cannot mix with focused profiles: $selected_target"
                    target_plan_valid=0
                    ;;
            esac
        fi
    done <"$selected_targets_file"

    if [ "$target_plan_valid" -ne 1 ]; then
        return
    fi
    while IFS= read -r selected_target || [ -n "$selected_target" ]; do
        run_target_gates "$selected_target"
    done <"$selected_targets_file"
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

affected_plan_ready=0
target_plan_ready=0
if [ "$profile" = "affected" ]; then
    if ! command -v git >/dev/null 2>&1; then
        record_fail "toolchain/git" "git is required by the affected profile"
    elif ! base_commit=$(
        git rev-parse --verify --end-of-options "${base_ref}^{commit}" 2>/dev/null
    ); then
        record_fail "verifier/base" "cannot resolve base revision: $base_ref"
    elif ! merge_base=$(git merge-base HEAD "$base_commit" 2>/dev/null); then
        record_fail "verifier/base" "cannot find a merge base with: $base_ref"
    elif [ "$has_python" -ne 1 ]; then
        record_fail "policy/affected-selection" \
            "requires a working python3 executable"
    elif ! python3 tools/verification_policy.py git-paths \
        --merge-base "$merge_base" \
        --paths0 "$affected_paths_file"; then
        record_fail "verifier/paths" \
            "cannot collect committed, staged, unstaged, and untracked paths"
    else
        printf 'Affected base: %s\n' "$base_ref"
        printf 'Resolved merge base: %s\n' "$merge_base"
        if python3 tools/verification_policy.py plan \
            --paths0 "$affected_paths_file" \
            --flags "$affected_flags_file" \
            --targets "$selected_targets_file" \
            --target-steps "$selected_target_steps_file"; then
            affected_plan_ready=1
            target_plan_ready=1
            record_pass "policy/affected-selection" "union plan created"
        else
            record_fail "policy/affected-selection" "cannot classify changed paths"
        fi
    fi
elif [ "$profile" = "matrix" ]; then
    if [ "$has_python" -eq 1 ] &&
        python3 tools/verification_policy.py retained-targets \
            --targets "$selected_targets_file" \
            --target-steps "$selected_target_steps_file"; then
        target_plan_ready=1
        record_pass "policy/target-selection" "retained target plan created"
    else
        record_fail "policy/target-selection" \
            "cannot create the retained target plan"
    fi
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

if [ "$profile" = "affected" ] &&
    [ "$affected_plan_ready" -eq 1 ] &&
    plan_has "python-changed"; then
    if [ "$has_python" -eq 1 ]; then
        run_gate "python/changed-syntax" \
            python3 tools/verification_policy.py python-syntax \
            --paths0 "$affected_paths_file"
    else
        record_skip "python/changed-syntax" "requires a working python3 executable"
    fi
fi

if [ "$profile" = "affected" ] &&
    [ "$affected_plan_ready" -eq 1 ] &&
    plan_has "shell-changed"; then
    if [ "$has_python" -eq 1 ]; then
        run_gate "shell/changed-syntax" \
            python3 tools/verification_policy.py shell-syntax \
            --paths0 "$affected_paths_file"
    else
        record_skip "shell/changed-syntax" "requires a working python3 executable"
    fi
fi

run_native_full=0
run_python_full=0
native_full_status=not-run
case "$profile" in
    full | matrix)
        run_native_full=1
        run_python_full=1
        ;;
    affected)
        if [ "$affected_plan_ready" -eq 1 ] && plan_has "native-full"; then
            run_native_full=1
        fi
        if [ "$affected_plan_ready" -eq 1 ] && plan_has "python-full"; then
            run_python_full=1
        fi
        ;;
esac

if [ "$run_native_full" -eq 1 ]; then
    if [ "$has_zig" -eq 1 ]; then
        run_gate "native/releasesafe-suite" \
            run_zig_build test
        native_full_status=$last_gate_status
    else
        native_full_status=unavailable
        record_skip "native/releasesafe-suite" "requires a working zig executable"
    fi
elif [ "$profile" = "quick" ]; then
    record_skip "native/releasesafe-suite" "quick profile; run tools/verify.sh full"
else
    record_skip "native/releasesafe-suite" "not selected by the affected policy"
fi

if [ "$run_python_full" -eq 1 ]; then
    if [ "$has_python" -eq 1 ]; then
        run_gate "python/full-suite" \
            python3 -m unittest discover -s bench/tests
    else
        record_skip "python/full-suite" "requires a working python3 executable"
    fi
elif [ "$profile" = "quick" ]; then
    record_skip "python/full-suite" "quick profile; run tools/verify.sh full"
else
    record_skip "python/full-suite" "not selected by the affected policy"
fi

host_name=$(uname -s 2>/dev/null || printf unknown)
host_arch=$(uname -m 2>/dev/null || printf unknown)
run_rust_gate=0
require_rust_gate=0
case "$profile" in
    full | matrix)
        run_rust_gate=1
        ;;
    quick)
        record_skip "interop/rust" "quick profile; run tools/verify.sh full"
        ;;
    affected)
        if [ "$affected_plan_ready" -eq 1 ] && plan_has "rust-native"; then
            run_rust_gate=1
            require_rust_gate=1
        else
            record_skip "interop/rust" "not selected by the affected policy"
        fi
        ;;
esac

if [ "$run_rust_gate" -eq 1 ]; then
    case "$host_name" in
        Darwin | Linux | FreeBSD)
            if ! command -v rustc >/dev/null 2>&1; then
                if [ "$require_rust_gate" -eq 1 ]; then
                    record_fail "interop/rust" \
                        "changed Rust source requires rustc on PATH"
                else
                    record_skip "interop/rust" "optional rustc is not on PATH"
                fi
            elif [ "$has_zig" -eq 1 ]; then
                run_gate "interop/rust" \
                    run_zig_build contract-rust-test
            elif [ "$require_rust_gate" -eq 1 ]; then
                record_fail "interop/rust" \
                    "changed Rust source requires a working zig executable"
            else
                record_skip "interop/rust" \
                    "requires a working zig executable"
            fi
            ;;
        *)
            if [ "$require_rust_gate" -eq 1 ]; then
                record_fail "interop/rust" \
                    "changed Rust source requires native macOS, Linux, or FreeBSD"
            else
                record_skip "interop/rust" \
                    "unsupported host for the retained native Rust gate"
            fi
            ;;
    esac
fi

if [ "$profile" = "affected" ] &&
    [ "$affected_plan_ready" -eq 1 ] &&
    plan_has "darwin-native"; then
    if [ "$host_name" != "Darwin" ]; then
        record_native_unavailable "native/darwin" \
            "requires native Darwin execution"
    else
        run_or_reuse_native_suite "native/darwin"
    fi
fi

if [ "$profile" = "affected" ] &&
    [ "$affected_plan_ready" -eq 1 ] &&
    plan_has "darwin-aarch64-native"; then
    if [ "$host_name" != "Darwin" ]; then
        record_native_unavailable "native/darwin-aarch64" \
            "requires native Darwin AArch64 execution"
    elif [ "$host_arch" != "arm64" ] && [ "$host_arch" != "aarch64" ]; then
        record_native_unavailable "native/darwin-aarch64" \
            "requires native Darwin AArch64 execution"
    else
        run_or_reuse_native_suite "native/darwin-aarch64"
    fi
fi

if [ "$profile" = "affected" ] &&
    [ "$affected_plan_ready" -eq 1 ] &&
    plan_has "darwin-swift"; then
    if [ "$host_name" != "Darwin" ]; then
        record_native_unavailable "native/darwin-swift" \
            "requires native Darwin execution"
    elif [ ! -x /usr/bin/swiftc ]; then
        record_native_unavailable "native/darwin-swift" \
            "requires /usr/bin/swiftc"
    else
        run_gate "native/darwin-swift" \
            /usr/bin/swiftc -typecheck bench/lane4_process_info.swift
    fi
fi

if [ "$profile" = "affected" ] &&
    [ "$affected_plan_ready" -eq 1 ] &&
    plan_has "metal-native"; then
    if [ "$host_name" != "Darwin" ]; then
        record_native_unavailable "native/metal" \
            "requires native Darwin execution"
    elif [ "$has_zig" -eq 1 ]; then
        run_gate "native/metal" run_zig_metal_build
    else
        record_native_unavailable "native/metal" \
            "requires a working zig executable"
    fi
fi

record_skip "native/debug-releasefast" \
    "change-specific matrix; see docs/CONTRIBUTING.md"
record_skip "concurrency/thread-sanitizer" \
    "run only on a supported host for concurrency changes"

case "$profile" in
    matrix)
        selected_target_count=0
        if [ "$target_plan_ready" -eq 1 ]; then
            run_target_plan
        fi
        if [ "$selected_target_count" -eq 0 ]; then
            record_fail "portability/cross-target" \
                "matrix requires a nonempty validated target plan"
        fi
        ;;
    affected)
        selected_target_count=0
        if [ "$affected_plan_ready" -eq 1 ] &&
            [ "$target_plan_ready" -eq 1 ]; then
            run_target_plan
        fi
        if [ "$selected_target_count" -eq 0 ]; then
            record_skip "portability/cross-target" \
                "no retained foreign target was selected"
        fi
        ;;
    quick | full)
        record_skip "portability/cross-target" \
            "run the affected targets from docs/CONTRIBUTING.md"
        ;;
esac

printf 'Summary: %s PASS, %s SKIP, %s FAIL\n' \
    "$pass_count" "$skip_count" "$fail_count"

if [ "$fail_count" -ne 0 ]; then
    exit 1
fi
exit 0
