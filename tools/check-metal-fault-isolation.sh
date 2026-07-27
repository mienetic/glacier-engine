#!/bin/sh
set -eu

if [ "$#" -ne 2 ]; then
    echo "usage: $0 PRODUCTION_SHIM FAULT_SHIM" >&2
    exit 2
fi

production_shim=$1
fault_shim=$2
symbol_prefix='_glacier_metal_test_'
arm_symbol='_glacier_metal_test_arm_next_completed_as_command_error_v1'
facts_symbol='_glacier_metal_test_completion_facts_for_binding_v1'
retirement_symbol='_glacier_metal_test_registered_dispatch_retirement_prepare'
hold_arm_symbol='_glacier_metal_test_arm_next_completion_callback_hold'
hold_wait_symbol='_glacier_metal_test_wait_for_held_completion_callback'
registered_wait_symbol='_glacier_metal_test_wait_for_registered_dispatch_waiter'
hold_release_symbol='_glacier_metal_test_release_held_completion_callback'
retirement_fail_symbol='_glacier_metal_test_arm_next_dispatch_retirement_commit_failure'
retirement_facts_symbol='_glacier_metal_test_dispatch_retirement_commit_facts'

production_symbols=$(/usr/bin/nm -gU "$production_shim")
if printf '%s\n' "$production_symbols" |
    /usr/bin/grep -q "$symbol_prefix"; then
    echo "production Metal shim exports a test-fault symbol" >&2
    exit 1
fi

fault_symbols=$(/usr/bin/nm -gU "$fault_shim")
for required_symbol in \
    "$arm_symbol" \
    "$facts_symbol" \
    "$retirement_symbol" \
    "$hold_arm_symbol" \
    "$hold_wait_symbol" \
    "$registered_wait_symbol" \
    "$hold_release_symbol" \
    "$retirement_fail_symbol" \
    "$retirement_facts_symbol"; do
    if ! printf '%s\n' "$fault_symbols" |
        /usr/bin/grep -q "${required_symbol}\$"; then
        echo "fault Metal shim is missing $required_symbol" >&2
        exit 1
    fi
done
