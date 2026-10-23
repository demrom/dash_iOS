#!/bin/bash
set -euo pipefail
export LC_ALL=C
if [[ $# != 4 ]]; then
    echo 'Usage: bash ci/dash/audit-exports.sh product candidate.zip published.zip ios_system.zip' >&2
    exit 2
fi
product=$1; artifact=$2; baseline=$3; core=$4
script_dir=$(cd "$(dirname "$0")" && pwd)
sha=$(awk -F '\t' -v product="$product" '$1==product {print $2}' "$script_dir/published.tsv")
test -n "$sha"
printf '%s  %s\n' "$sha" "$baseline" | shasum -a 256 -c -
temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT
unzip -q "$artifact" -d "$temporary/candidate"
unzip -q "$baseline" -d "$temporary/published"
unzip -q "$core" -d "$temporary/core"
old="$temporary/published/$product.xcframework/ios-arm64/$product.framework/$product"
xcrun nm -arch arm64 -gjU "$old" | sort -u > "$temporary/old.txt"
test "$(wc -l < "$temporary/old.txt" | tr -d ' ')" = 259
test "$(wc -l < "$script_dir/export-additions.txt" | tr -d ' ')" = 44
cat "$temporary/old.txt" "$script_dir/export-additions.txt" | sort -u > "$temporary/expected.txt"
test "$(wc -l < "$temporary/expected.txt" | tr -d ' ')" = 303
for spec in ios-arm64:arm64 ios-arm64_x86_64-simulator:arm64 ios-arm64_x86_64-simulator:x86_64; do
    slice=${spec%:*}; arch=${spec#*:}
    binary="$temporary/candidate/$product.xcframework/$slice/$product.framework/$product"
    runtime="$temporary/core/ios_system.xcframework/$slice/ios_system.framework/ios_system"
    xcrun nm -arch "$arch" -gjU "$binary" | sort -u > "$temporary/actual.txt"
    diff -u "$temporary/expected.txt" "$temporary/actual.txt"
    xcrun nm -arch "$arch" -gjU "$runtime" | sort -u > "$temporary/runtime.txt"
    xcrun nm -arch "$arch" -mu "$binary" | awk '$NF=="ios_system)" {print $(NF-2)}' | sort -u > "$temporary/imports.txt"
    test -s "$temporary/imports.txt"
    comm -23 "$temporary/imports.txt" "$temporary/runtime.txt" > "$temporary/missing.txt"
    test ! -s "$temporary/missing.txt" || { cat "$temporary/missing.txt" >&2; exit 1; }
    xcrun otool -arch "$arch" -L "$binary" | awk '/^\t/ {print $1}' > "$temporary/dependencies.txt"
    while IFS= read -r dependency; do
        case "$dependency" in
            "@rpath/$product.framework/$product"|@rpath/ios_system.framework/ios_system|/usr/lib/libSystem.B.dylib|/usr/lib/libncurses.5.4.dylib) ;;
            *) echo "Unexpected Dash dependency: $dependency" >&2; exit 1 ;;
        esac
    done < "$temporary/dependencies.txt"
    echo "PASS $product $slice $arch exports303/all259published+44pinned additions/core import closure"
done
