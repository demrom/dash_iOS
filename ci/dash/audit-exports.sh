#!/bin/bash
set -euo pipefail
export LC_ALL=C
if [[ $# != 3 ]]; then
    echo 'Usage: bash ci/dash/audit-exports.sh product candidate.zip ios_system.zip' >&2
    exit 2
fi
product=$1; artifact=$2; core=$3
script_dir=$(cd "$(dirname "$0")" && pwd)
temporary=$(mktemp -d)
trap 'rm -rf "$temporary"' EXIT
unzip -q "$artifact" -d "$temporary/candidate"
unzip -q "$core" -d "$temporary/core"
/usr/libexec/PlistBuddy -c 'Print :AvailableLibraries' "$temporary/candidate/$product.xcframework/Info.plist" >/dev/null
identifiers=$(plutil -extract AvailableLibraries json -o - "$temporary/candidate/$product.xcframework/Info.plist" | /usr/bin/python3 -c 'import json,sys; a=json.load(sys.stdin); expected={"ios-arm64", "ios-arm64_x86_64-simulator"}; ids=[x["LibraryIdentifier"] for x in a]; assert len(ids)==2 and set(ids)==expected, "Require exactly ios-arm64 and ios-arm64_x86_64-simulator"; print("exact2slices")')
test "$identifiers" = exact2slices
cp "$script_dir/published-exports.txt" "$temporary/old.txt"
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
