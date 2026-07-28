#!/bin/sh

set -eu

if [ "$#" -ne 1 ]; then
    echo "usage: tools/metal-toolchain-identity.sh OUTPUT" >&2
    exit 64
fi

output_path=$1
metal_tool=$(xcrun -sdk macosx --find metal)
metallib_tool=$(xcrun -sdk macosx --find metallib)
sdk_path=$(xcrun -sdk macosx --show-sdk-path)
resource_dir=$(xcrun -sdk macosx metal -print-resource-dir)
sdk_settings_json="$sdk_path/SDKSettings.json"
sdk_settings_plist="$sdk_path/SDKSettings.plist"
metal_include_dir="$resource_dir/include/metal"

for required_path in \
    "$metal_tool" \
    "$metallib_tool" \
    "$sdk_settings_json" \
    "$sdk_settings_plist"; do
    if [ ! -f "$required_path" ]; then
        echo "missing Metal toolchain identity input: $required_path" >&2
        exit 1
    fi
done
if [ ! -d "$metal_include_dir" ]; then
    echo "missing Metal standard-library directory: $metal_include_dir" >&2
    exit 1
fi

{
    printf 'identity_version=1\n'
    printf 'metal_tool=%s\n' "$metal_tool"
    printf 'metallib_tool=%s\n' "$metallib_tool"
    printf 'sdk_path=%s\n' "$sdk_path"
    printf 'resource_dir=%s\n' "$resource_dir"
    shasum -a 256 \
        "$metal_tool" \
        "$metallib_tool" \
        "$sdk_settings_json" \
        "$sdk_settings_plist"
    find "$metal_include_dir" -type f -exec shasum -a 256 {} + |
        LC_ALL=C sort
} |
    shasum -a 256 >"$output_path"
