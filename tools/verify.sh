#!/bin/sh

set -eu

usage() {
    cat <<'EOF'
usage: tools/verify.sh [quick|full|matrix]
       tools/verify.sh affected-fast --base REV
       tools/verify.sh affected --base REV
       GLACIER_VERIFY_BASE=REV tools/verify.sh affected-fast
       GLACIER_VERIFY_BASE=REV tools/verify.sh affected
       GLACIER_VERIFY_REQUIRE_NATIVE=1 tools/verify.sh affected --base REV

quick  Run bounded format, documentation-policy, package, and interop gates.
full   Add broad ReleaseSafe/Python, native POSIX store-fault, and optional Rust.
affected-fast
       Select changed-path syntax and focused native gates, while deferring
       broad ReleaseSafe/Python suites and retained cross-target compilation.
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
            affected | affected-fast)
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
    2)
        case "$1:$2" in
            affected:--base=* | affected-fast:--base=*)
                profile=$1
                base_ref=${2#--base=}
                ;;
            *)
                usage >&2
                exit 64
                ;;
        esac
        ;;
    3)
        case "$1:$2" in
            affected:--base | affected-fast:--base)
                profile=$1
                base_ref=$3
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

affected_profile=0
case "$profile" in
    affected | affected-fast) affected_profile=1 ;;
esac

if [ "$affected_profile" -eq 1 ] && [ -z "$base_ref" ]; then
    echo "FAIL  verifier/base: $profile requires --base REV or GLACIER_VERIFY_BASE" >&2
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

reuse_zig_cache=${GLACIER_VERIFY_REUSE_ZIG_CACHE:-0}
case "$reuse_zig_cache" in
    0 | 1) ;;
    *)
        echo "FAIL  verifier/zig-cache: GLACIER_VERIFY_REUSE_ZIG_CACHE must be 0 or 1" >&2
        exit 64
        ;;
esac
inherited_zig_local_cache=${ZIG_LOCAL_CACHE_DIR:-}
inherited_zig_global_cache=${ZIG_GLOBAL_CACHE_DIR:-}

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

reused_zig_cache=
if [ "$reuse_zig_cache" -eq 1 ]; then
    if [ "${GITHUB_ACTIONS:-}" != "true" ]; then
        echo "FAIL  verifier/zig-cache: reuse is restricted to GitHub Actions" >&2
        exit 64
    fi
    case "$inherited_zig_local_cache:$inherited_zig_global_cache" in
        /*:/*) ;;
        *)
            echo "FAIL  verifier/zig-cache: action cache paths must be absolute" >&2
            exit 64
            ;;
    esac
    # The pinned setup-zig action exports both caches at this workspace path.
    expected_zig_cache="$repository_root/.zig-cache"
    if [ "$inherited_zig_local_cache" != "$expected_zig_cache" ] ||
        [ "$inherited_zig_global_cache" != "$expected_zig_cache" ]; then
        echo "FAIL  verifier/zig-cache: action cache paths must both name $expected_zig_cache" >&2
        exit 64
    fi
    if [ -L "$expected_zig_cache" ]; then
        echo "FAIL  verifier/zig-cache: action cache path must not be a symlink" >&2
        exit 64
    fi
    if [ -e "$expected_zig_cache" ] && [ ! -d "$expected_zig_cache" ]; then
        echo "FAIL  verifier/zig-cache: action cache path must be a directory" >&2
        exit 64
    fi
    if [ ! -d "$expected_zig_cache" ]; then
        mkdir "$expected_zig_cache" || {
            echo "FAIL  verifier/zig-cache: cannot create action cache directory" >&2
            exit 1
        }
    fi
    reused_zig_cache=$(
        CDPATH= cd "$expected_zig_cache" 2>/dev/null &&
            pwd -P
    ) || {
        echo "FAIL  verifier/zig-cache: cannot resolve action cache directory" >&2
        exit 1
    }
    if [ "$reused_zig_cache" != "$expected_zig_cache" ]; then
        echo "FAIL  verifier/zig-cache: action cache resolved outside the repository path" >&2
        exit 64
    fi
fi

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
mkdir \
    "$verification_root/logs" \
    "$verification_root/clang-module-cache" \
    "$verification_root/swift-module-cache" || {
    echo "FAIL  verifier/cache: cannot create temporary directories" >&2
    exit 1
}

if [ "$reuse_zig_cache" -eq 1 ]; then
    ZIG_LOCAL_CACHE_DIR=$reused_zig_cache
    ZIG_GLOBAL_CACHE_DIR=$reused_zig_cache
else
    ZIG_LOCAL_CACHE_DIR="$verification_root/zig-local"
    ZIG_GLOBAL_CACHE_DIR="$verification_root/zig-global"
fi
CLANG_MODULE_CACHE_PATH="$verification_root/clang-module-cache"
SWIFT_MODULECACHE_PATH="$verification_root/swift-module-cache"
verification_prefix="$verification_root/prefix"
affected_paths_file="$verification_root/affected.paths0"
affected_flags_file="$verification_root/affected.flags"
selected_targets_file="$verification_root/selected.targets"
selected_target_steps_file="$verification_root/selected.target-steps"
PYTHONDONTWRITEBYTECODE=1
export \
    ZIG_LOCAL_CACHE_DIR \
    ZIG_GLOBAL_CACHE_DIR \
    CLANG_MODULE_CACHE_PATH \
    SWIFT_MODULECACHE_PATH \
    PYTHONDONTWRITEBYTECODE

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

run_prepared_text_focused_build() {
    set --
    if [ "$generic_host_zig_requested" -eq 1 ]; then
        set -- "$@" contract-interop-test package-module-test
    fi
    if [ "$prepared_text_unary_service_requested" -eq 1 ]; then
        set -- "$@" unary-text-service-test
    fi
    if [ "$prepared_text_unary_http_requested" -eq 1 ]; then
        set -- "$@" unary-http-test
    fi
    if [ "$prepared_text_package_text_run_requested" -eq 1 ]; then
        set -- "$@" text-runtime-golden-path-test
    fi
    if [ "$prepared_text_delivery_requested" -eq 1 ]; then
        set -- "$@" prepared-text-acknowledged-delivery-test
    fi
    if [ "$prepared_text_direct_terminal_smoke_requested" -eq 1 ] &&
        [ "$prepared_text_recovery_requested" -eq 0 ]; then
        set -- "$@" prepared-text-direct-terminal-recovery-smoke-test
    fi
    if [ "$prepared_text_recovery_requested" -eq 1 ]; then
        set -- "$@" prepared-text-recovery-test
    fi
    if [ "$prepared_text_inspector_requested" -eq 1 ]; then
        set -- "$@" prepared-text-result-inspector-test
    fi
    [ "$#" -gt 0 ] || return 64
    run_zig_build "$@"
}

run_zig_metal_build() {
    zig build native-metal-suite-compile \
        -Dmetal-output-dir="$verification_root/metal" \
        -Doptimize=ReleaseSafe \
        -Dmetal=true \
        -j2 \
        --cache-dir "$ZIG_LOCAL_CACHE_DIR" \
        --global-cache-dir "$ZIG_GLOBAL_CACHE_DIR" \
        --prefix "$verification_root/prefix-metal" ||
        return $?
    zig build native-metal-suite-test \
        -Dmetal-output-dir="$verification_root/metal" \
        -Doptimize=ReleaseSafe \
        -Dmetal=true \
        -j1 \
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
            "covered by the shared host runtime DAG"
    elif [ "$native_full_status" = "unavailable-zig" ]; then
        record_native_unavailable "$native_gate" \
            "requires a working zig executable"
    elif [ "$native_full_status" = "unavailable-python" ]; then
        record_native_unavailable "$native_gate" \
            "requires a working python3 executable"
    elif [ "$native_full_status" != "not-run" ]; then
        record_fail "$native_gate" \
            "covering host compile or runtime DAG failed"
    elif [ "$has_zig" -eq 1 ] && [ "$has_python" -eq 1 ]; then
        run_gate "$native_gate" run_zig_build test
    elif [ "$has_zig" -eq 1 ]; then
        record_native_unavailable "$native_gate" \
            "requires a working python3 executable"
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
            install | install-benchmarks | test-compile | unary-text-service-compile | unary-http-compile | profile-core-compile | profile-cpu-compile | profile-durable-compile | profile-device-compile | profile-host-tool-compile | profile-complete-compile) ;;
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
                unary-text-service-compile) profile_rank=1 ;;
                unary-http-compile) profile_rank=2 ;;
                profile-core-compile) profile_rank=3 ;;
                profile-cpu-compile) profile_rank=4 ;;
                profile-durable-compile) profile_rank=5 ;;
                profile-device-compile) profile_rank=6 ;;
                profile-host-tool-compile) profile_rank=7 ;;
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

host_name=$(uname -s 2>/dev/null || printf unknown)
host_arch=$(uname -m 2>/dev/null || printf unknown)

affected_plan_ready=0
target_plan_ready=0
if [ "$affected_profile" -eq 1 ]; then
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

generic_host_zig_requested=1
prepared_text_focused_requested=0
prepared_text_unary_service_requested=0
prepared_text_unary_http_requested=0
prepared_text_delivery_requested=0
prepared_text_direct_terminal_smoke_requested=0
prepared_text_inspector_requested=0
prepared_text_package_text_run_requested=0
prepared_text_recovery_requested=0
if [ "$affected_plan_ready" -eq 1 ] &&
    plan_has "prepared-text-unary-service-focused"; then
    prepared_text_unary_service_requested=1
    prepared_text_focused_requested=1
fi
if [ "$affected_plan_ready" -eq 1 ] &&
    plan_has "prepared-text-unary-http-focused"; then
    prepared_text_unary_http_requested=1
    prepared_text_focused_requested=1
fi
if [ "$affected_plan_ready" -eq 1 ] &&
    plan_has "prepared-text-package-text-run-focused"; then
    prepared_text_package_text_run_requested=1
    prepared_text_focused_requested=1
fi
if [ "$affected_plan_ready" -eq 1 ] &&
    plan_has "prepared-text-delivery-focused"; then
    prepared_text_delivery_requested=1
    prepared_text_focused_requested=1
fi
if [ "$affected_plan_ready" -eq 1 ] &&
    plan_has "prepared-text-direct-terminal-smoke-focused"; then
    prepared_text_direct_terminal_smoke_requested=1
    prepared_text_focused_requested=1
fi
if [ "$affected_plan_ready" -eq 1 ] &&
    plan_has "prepared-text-recovery-focused"; then
    prepared_text_recovery_requested=1
    prepared_text_focused_requested=1
fi
if [ "$affected_plan_ready" -eq 1 ] &&
    plan_has "prepared-text-inspector-focused"; then
    prepared_text_inspector_requested=1
    prepared_text_focused_requested=1
fi
if [ "$affected_profile" -eq 1 ] &&
    [ "$affected_plan_ready" -eq 1 ]; then
    generic_host_zig_requested=0
    if plan_has "host-quick"; then
        generic_host_zig_requested=1
    fi
fi

prepared_text_native_host_available=0
if [ "$prepared_text_focused_requested" -eq 1 ]; then
    case "$host_name" in
        Darwin | Linux) prepared_text_native_host_available=1 ;;
    esac
fi
host_zig_requested=$generic_host_zig_requested
if [ "$prepared_text_native_host_available" -eq 1 ]; then
    host_zig_requested=1
fi

run_native_full=0
run_python_full=0
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

host_quick_status=not-run
prepared_text_focused_in_quick=0
if [ "$run_native_full" -eq 1 ]; then
    :
elif [ "$host_zig_requested" -eq 0 ]; then
    record_skip "interop/c-cpp-python" \
        "affected plan selected no generic host Zig DAG"
    record_skip "package/modules" \
        "affected plan selected no generic host Zig DAG"
elif [ "$has_zig" -eq 1 ] && [ "$has_python" -eq 1 ]; then
    if [ "$prepared_text_native_host_available" -eq 1 ]; then
        prepared_text_focused_in_quick=1
        run_gate "host/prepared-text-focused-dag" \
            run_prepared_text_focused_build
    else
        run_gate "host/quick-dag" \
            run_zig_build contract-interop-test package-module-test
    fi
    host_quick_status=$last_gate_status
    if [ "$host_quick_status" -eq 0 ]; then
        if [ "$generic_host_zig_requested" -eq 1 ]; then
            record_pass "interop/c-cpp-python" \
                "covered by the shared host Zig DAG"
            record_pass "package/modules" \
                "covered by the shared host Zig DAG"
        elif [ "$prepared_text_focused_in_quick" -eq 1 ]; then
            record_skip "interop/c-cpp-python" \
                "prepared-text focused DAG does not select generic interop"
            record_skip "package/modules" \
                "prepared-text focused DAG does not select generic package modules"
        fi
    else
        record_skip "interop/c-cpp-python" \
            "shared host Zig DAG failed"
        record_skip "package/modules" \
            "shared host Zig DAG failed"
    fi
else
    record_skip "interop/c-cpp-python" "requires both zig and python3"
    if [ "$has_zig" -eq 1 ]; then
        run_gate "package/modules" \
            run_zig_build package-module-test
    else
        record_skip "package/modules" \
            "requires a working zig executable"
    fi
fi

if [ "$prepared_text_focused_requested" -eq 1 ] &&
    [ "$prepared_text_focused_in_quick" -eq 1 ]; then
    if [ "$host_quick_status" -eq 0 ]; then
        if [ "$prepared_text_unary_service_requested" -eq 1 ]; then
            record_pass "native/prepared-text-unary-service" \
                "covered by the focused host Zig DAG"
        fi
        if [ "$prepared_text_unary_http_requested" -eq 1 ]; then
            record_pass "native/prepared-text-unary-http" \
                "covered by the focused host Zig DAG"
        fi
        if [ "$prepared_text_delivery_requested" -eq 1 ]; then
            record_pass "native/prepared-text-delivery" \
                "covered by the focused host Zig DAG"
        fi
        if [ "$prepared_text_direct_terminal_smoke_requested" -eq 1 ]; then
            record_pass "native/prepared-text-direct-terminal-smoke" \
                "covered by the focused host Zig DAG"
        fi
        if [ "$prepared_text_inspector_requested" -eq 1 ]; then
            record_pass "native/prepared-text-inspector" \
                "covered by the focused host Zig DAG"
        fi
        if [ "$prepared_text_package_text_run_requested" -eq 1 ]; then
            record_pass "native/prepared-text-package-text-run" \
                "covered by the focused host Zig DAG"
        fi
        if [ "$prepared_text_recovery_requested" -eq 1 ]; then
            record_pass "native/prepared-text-recovery" \
                "covered by the focused host Zig DAG"
        fi
    else
        if [ "$prepared_text_unary_service_requested" -eq 1 ]; then
            record_skip "native/prepared-text-unary-service" \
                "focused host Zig DAG failed"
        fi
        if [ "$prepared_text_unary_http_requested" -eq 1 ]; then
            record_skip "native/prepared-text-unary-http" \
                "focused host Zig DAG failed"
        fi
        if [ "$prepared_text_delivery_requested" -eq 1 ]; then
            record_skip "native/prepared-text-delivery" \
                "focused host Zig DAG failed"
        fi
        if [ "$prepared_text_direct_terminal_smoke_requested" -eq 1 ]; then
            record_skip "native/prepared-text-direct-terminal-smoke" \
                "focused host Zig DAG failed"
        fi
        if [ "$prepared_text_inspector_requested" -eq 1 ]; then
            record_skip "native/prepared-text-inspector" \
                "focused host Zig DAG failed"
        fi
        if [ "$prepared_text_package_text_run_requested" -eq 1 ]; then
            record_skip "native/prepared-text-package-text-run" \
                "focused host Zig DAG failed"
        fi
        if [ "$prepared_text_recovery_requested" -eq 1 ]; then
            record_skip "native/prepared-text-recovery" \
                "focused host Zig DAG failed"
        fi
    fi
elif [ "$prepared_text_focused_requested" -eq 1 ] &&
    [ "$run_native_full" -eq 0 ]; then
    if [ "$host_name" != "Darwin" ] && [ "$host_name" != "Linux" ]; then
        if [ "$prepared_text_unary_service_requested" -eq 1 ]; then
            record_native_unavailable \
                "native/prepared-text-unary-service" \
                "requires native macOS or Linux execution"
        fi
        if [ "$prepared_text_unary_http_requested" -eq 1 ]; then
            record_native_unavailable \
                "native/prepared-text-unary-http" \
                "requires native macOS or Linux execution"
        fi
        if [ "$prepared_text_delivery_requested" -eq 1 ]; then
            record_native_unavailable "native/prepared-text-delivery" \
                "requires native macOS or Linux execution"
        fi
        if [ "$prepared_text_direct_terminal_smoke_requested" -eq 1 ]; then
            record_native_unavailable \
                "native/prepared-text-direct-terminal-smoke" \
                "requires native macOS or Linux execution"
        fi
        if [ "$prepared_text_inspector_requested" -eq 1 ]; then
            record_native_unavailable "native/prepared-text-inspector" \
                "requires native macOS or Linux execution"
        fi
        if [ "$prepared_text_package_text_run_requested" -eq 1 ]; then
            record_native_unavailable "native/prepared-text-package-text-run" \
                "requires native macOS or Linux execution"
        fi
        if [ "$prepared_text_recovery_requested" -eq 1 ]; then
            record_native_unavailable "native/prepared-text-recovery" \
                "requires native macOS or Linux execution"
        fi
    else
        if [ "$prepared_text_unary_service_requested" -eq 1 ]; then
            record_native_unavailable \
                "native/prepared-text-unary-service" \
                "requires working zig and python3 executables"
        fi
        if [ "$prepared_text_unary_http_requested" -eq 1 ]; then
            record_native_unavailable \
                "native/prepared-text-unary-http" \
                "requires working zig and python3 executables"
        fi
        if [ "$prepared_text_delivery_requested" -eq 1 ]; then
            record_native_unavailable "native/prepared-text-delivery" \
                "requires working zig and python3 executables"
        fi
        if [ "$prepared_text_direct_terminal_smoke_requested" -eq 1 ]; then
            record_native_unavailable \
                "native/prepared-text-direct-terminal-smoke" \
                "requires working zig and python3 executables"
        fi
        if [ "$prepared_text_inspector_requested" -eq 1 ]; then
            record_native_unavailable "native/prepared-text-inspector" \
                "requires working zig and python3 executables"
        fi
        if [ "$prepared_text_package_text_run_requested" -eq 1 ]; then
            record_native_unavailable "native/prepared-text-package-text-run" \
                "requires working zig and python3 executables"
        fi
        if [ "$prepared_text_recovery_requested" -eq 1 ]; then
            record_native_unavailable "native/prepared-text-recovery" \
                "requires working zig and python3 executables"
        fi
    fi
fi

if [ "$affected_profile" -eq 1 ] &&
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

if [ "$profile" = "affected-fast" ] &&
    [ "$affected_plan_ready" -eq 1 ] &&
    plan_has "verification-policy-focused"; then
    if [ "$has_python" -eq 1 ]; then
        run_gate "python/verification-policy" \
            python3 -m unittest \
            bench.tests.test_local_verify \
            bench.tests.test_verification_policy
    else
        record_skip "python/verification-policy" \
            "requires a working python3 executable"
    fi
fi

if [ "$affected_profile" -eq 1 ] &&
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

if [ "$affected_profile" -eq 1 ] &&
    [ "$affected_plan_ready" -eq 1 ] &&
    plan_has "workload-report-portable"; then
    if [ "$has_zig" -eq 1 ] && [ "$has_python" -eq 1 ]; then
        run_gate "portable/workload-report" \
            run_zig_build \
            native-workload-report-test \
            native-workload-report-compile \
            native-workload-report-cross-compile \
            native-workload-campaign-test \
            native-workload-campaign-compile \
            native-workload-campaign-cross-compile \
            native-workload-store-fault-report-test \
            native-workload-store-fault-report-compile \
            native-workload-store-fault-report-cross-compile \
            native-supervisor-recovery-death-report-test \
            native-supervisor-recovery-death-report-compile \
            native-supervisor-recovery-death-report-cross-compile
    else
        record_skip "portable/workload-report" \
            "requires working zig and python3 executables"
    fi
fi

native_full_status=not-run
host_compile_status=not-run

if [ "$run_native_full" -eq 1 ]; then
    if [ "$has_zig" -eq 1 ]; then
        run_gate "compile/host-test-frontier" \
            run_zig_build host-runtime-compile
        host_compile_status=$last_gate_status
        if [ "$host_compile_status" -eq 0 ]; then
            if [ "$has_python" -eq 1 ]; then
                run_gate "host/runtime-dag" \
                    run_zig_build test contract-interop-test
                native_full_status=$last_gate_status
                if [ "$native_full_status" -eq 0 ]; then
                    record_pass "native/releasesafe-suite" \
                        "covered by the shared host runtime DAG"
                    record_pass "interop/c-cpp-python" \
                        "covered by the shared host runtime DAG"
                    record_pass "package/modules" \
                        "covered by the shared host runtime DAG"
                else
                    record_skip "native/releasesafe-suite" \
                        "shared host runtime DAG failed"
                    record_skip "interop/c-cpp-python" \
                        "shared host runtime DAG failed"
                    record_skip "package/modules" \
                        "shared host runtime DAG failed"
                fi
            else
                native_full_status=unavailable-python
                record_skip "host/runtime-dag" \
                    "requires a working python3 executable"
                record_skip "native/releasesafe-suite" \
                    "requires a working python3 executable"
                record_skip "interop/c-cpp-python" \
                    "requires a working python3 executable"
                run_gate "package/modules" \
                    run_zig_build package-module-test
            fi
        else
            native_full_status=compile-failed
            record_skip "host/runtime-dag" \
                "host test compile frontier failed"
            record_skip "native/releasesafe-suite" \
                "host test compile frontier failed"
            record_skip "interop/c-cpp-python" \
                "host test compile frontier failed"
            record_skip "package/modules" \
                "host test compile frontier failed"
        fi
    else
        native_full_status=unavailable-zig
        record_skip "compile/host-test-frontier" \
            "requires a working zig executable"
        record_skip "host/runtime-dag" \
            "requires a working zig executable"
        record_skip "native/releasesafe-suite" \
            "requires a working zig executable"
        record_skip "interop/c-cpp-python" \
            "requires a working zig executable"
        record_skip "package/modules" \
            "requires a working zig executable"
    fi
elif [ "$profile" = "quick" ]; then
    record_skip "native/releasesafe-suite" "quick profile; run tools/verify.sh full"
elif [ "$profile" = "affected-fast" ]; then
    record_skip "native/releasesafe-suite" \
        "affected-fast defers the broad suite; run affected with the same base"
else
    record_skip "native/releasesafe-suite" "not selected by the affected policy"
fi

if [ "$profile" = "affected" ] &&
    [ "$prepared_text_focused_requested" -eq 1 ] &&
    [ "$prepared_text_focused_in_quick" -eq 0 ]; then
    if [ "$native_full_status" = "0" ]; then
        if [ "$prepared_text_delivery_requested" -eq 1 ]; then
            record_pass "native/prepared-text-delivery" \
                "covered by the shared host runtime DAG"
        fi
        if [ "$prepared_text_direct_terminal_smoke_requested" -eq 1 ]; then
            record_pass "native/prepared-text-direct-terminal-smoke" \
                "covered by the shared host runtime DAG"
        fi
        if [ "$prepared_text_inspector_requested" -eq 1 ]; then
            record_pass "native/prepared-text-inspector" \
                "covered by the shared host runtime DAG"
        fi
        if [ "$prepared_text_package_text_run_requested" -eq 1 ]; then
            record_pass "native/prepared-text-package-text-run" \
                "covered by the shared host runtime DAG"
        fi
        if [ "$prepared_text_recovery_requested" -eq 1 ]; then
            record_pass "native/prepared-text-recovery" \
                "covered by the shared host runtime DAG"
        fi
    else
        if [ "$prepared_text_delivery_requested" -eq 1 ]; then
            record_skip "native/prepared-text-delivery" \
                "covering host compile or runtime DAG did not pass"
        fi
        if [ "$prepared_text_direct_terminal_smoke_requested" -eq 1 ]; then
            record_skip "native/prepared-text-direct-terminal-smoke" \
                "covering host compile or runtime DAG did not pass"
        fi
        if [ "$prepared_text_inspector_requested" -eq 1 ]; then
            record_skip "native/prepared-text-inspector" \
                "covering host compile or runtime DAG did not pass"
        fi
        if [ "$prepared_text_package_text_run_requested" -eq 1 ]; then
            record_skip "native/prepared-text-package-text-run" \
                "covering host compile or runtime DAG did not pass"
        fi
        if [ "$prepared_text_recovery_requested" -eq 1 ]; then
            record_skip "native/prepared-text-recovery" \
                "covering host compile or runtime DAG did not pass"
        fi
    fi
fi

python_full_status=not-run
if [ "$run_python_full" -eq 1 ]; then
    if [ "$has_python" -eq 1 ]; then
        run_gate "python/full-suite" \
            python3 -m unittest discover -s bench/tests
        python_full_status=$last_gate_status
    else
        python_full_status=unavailable-python
        record_skip "python/full-suite" "requires a working python3 executable"
    fi
elif [ "$profile" = "quick" ]; then
    record_skip "python/full-suite" "quick profile; run tools/verify.sh full"
elif [ "$profile" = "affected-fast" ]; then
    record_skip "python/full-suite" \
        "affected-fast defers full discovery; run affected with the same base"
else
    record_skip "python/full-suite" "not selected by the affected policy"
fi

if [ "$profile" = "affected" ] &&
    [ "$affected_plan_ready" -eq 1 ] &&
    plan_has "verification-policy-focused"; then
    if [ "$python_full_status" = "0" ]; then
        record_pass "python/verification-policy" \
            "covered by full Python discovery"
    else
        record_skip "python/verification-policy" \
            "covering full Python discovery did not pass"
    fi
fi

run_workload_store_fault=0
case "$profile" in
    full | matrix)
        run_workload_store_fault=1
        ;;
    affected | affected-fast)
        if [ "$affected_plan_ready" -eq 1 ] &&
            plan_has "workload-store-fault-posix"; then
            run_workload_store_fault=1
        fi
        ;;
esac

if [ "$run_workload_store_fault" -eq 1 ] &&
    [ "$host_compile_status" != "not-run" ] &&
    [ "$host_compile_status" -ne 0 ]; then
    record_skip "native/workload-store-fault" \
        "host test compile frontier failed"
elif [ "$run_workload_store_fault" -eq 1 ]; then
    case "$host_name" in
        Darwin | Linux | FreeBSD)
            if [ "$has_zig" -eq 1 ] && [ "$has_python" -eq 1 ]; then
                run_gate "native/workload-store-fault" \
                    run_zig_build native-workload-store-fault-test
            else
                record_native_unavailable \
                    "native/workload-store-fault" \
                    "requires working zig and python3 executables"
            fi
            ;;
        *)
            record_native_unavailable \
                "native/workload-store-fault" \
                "requires native Darwin, Linux, or FreeBSD POSIX execution"
            ;;
    esac
fi

run_rust_gate=0
require_rust_gate=0
case "$profile" in
    full | matrix)
        run_rust_gate=1
        ;;
    quick)
        record_skip "interop/rust" "quick profile; run tools/verify.sh full"
        ;;
    affected | affected-fast)
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

if [ "$affected_profile" -eq 1 ] &&
    [ "$affected_plan_ready" -eq 1 ] &&
    plan_has "darwin-native"; then
    if [ "$profile" = "affected-fast" ]; then
        record_skip "native/darwin" \
            "affected-fast has no focused Darwin root; run affected with the same base"
    elif [ "$host_name" != "Darwin" ]; then
        record_native_unavailable "native/darwin" \
            "requires native Darwin execution"
    else
        run_or_reuse_native_suite "native/darwin"
    fi
fi

if [ "$affected_profile" -eq 1 ] &&
    [ "$affected_plan_ready" -eq 1 ] &&
    plan_has "darwin-aarch64-native"; then
    if [ "$profile" = "affected-fast" ]; then
        record_skip "native/darwin-aarch64" \
            "affected-fast has no focused Darwin AArch64 root; run affected with the same base"
    elif [ "$host_name" != "Darwin" ]; then
        record_native_unavailable "native/darwin-aarch64" \
            "requires native Darwin AArch64 execution"
    elif [ "$host_arch" != "arm64" ] && [ "$host_arch" != "aarch64" ]; then
        record_native_unavailable "native/darwin-aarch64" \
            "requires native Darwin AArch64 execution"
    else
        run_or_reuse_native_suite "native/darwin-aarch64"
    fi
fi

if [ "$affected_profile" -eq 1 ] &&
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

if [ "$affected_profile" -eq 1 ] &&
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
    affected-fast)
        record_skip "portability/cross-target" \
            "affected-fast defers retained targets; run affected with the same base"
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
