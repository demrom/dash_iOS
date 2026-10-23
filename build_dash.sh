#!/bin/bash
set -euo pipefail
export LC_ALL=C
repo=$(cd "$(dirname "$0")" && pwd)
root="$repo/.build/dash"
source_pin=8a7e0c2e0583c279579dca4e769487c503be47e2
core_pin=b51dd90d778499b3592258988423008515282196
mkdir -p "$root/inputs"
# Every rerun rebuilds owned outputs; verified downloads can be reused.
fetch() {
    local url=$1 sha=$2 output=$3
    if [[ ! -f $output ]]; then
        curl --fail --location --retry 3 "$url" -o "$output.download"
        printf '%s  %s\n' "$sha" "$output.download" | shasum -a 256 -c -
        mv "$output.download" "$output"
    fi
    printf '%s  %s\n' "$sha" "$output" | shasum -a 256 -c -
}
fetch https://thrysoee.dk/editline/libedit-20260512-3.1.tar.gz 432d5e7ea8b0116dd39f2eca7bc11d0eed77faa6b77ea526ace89907c23ea4a0 "$root/libedit-20260512-3.1.tar.gz"
fetch "https://codeload.github.com/holzschu/ios_system/tar.gz/$core_pin" e6c1a479e50af0ca34302838884bf3729c80e8a3f32e1638bd7efe46811be48d "$root/inputs/ios_system.tar.gz"
fetch https://ftp.gnu.org/gnu/automake/automake-1.19.tar.xz e3e2c2e3abf37898138db5b6c1d1dc35c9160c5978be7947d2c741705251d445 "$root/inputs/automake.tar.xz"
for directory in source core products audit automake; do
    rm -rf "$root/$directory"
    mkdir -p "$root/$directory"
done
source_dir="$root/source"
# Build only the verified source inputs from this checkout; no fork or Git history dependency.
printf '%s  %s\n' edd58f0540b05da847af10f529f567987112b3e28b570fadef21ed45c3c0c808 "$repo/ci/dash/source-checksums.txt" | shasum -a 256 -c -
(cd "$repo" && shasum -a 256 -c ci/dash/source-checksums.txt)
while read -r checksum member; do
    mkdir -p "$source_dir/$(dirname "$member")"
    cp "$repo/$member" "$source_dir/$member"
    # Equal source timestamps prevent accidental Autotools regeneration after checkout.
    touch -t 202001010000 "$source_dir/$member"
done < "$repo/ci/dash/source-checksums.txt"
chmod +x "$source_dir/configure"
printf '%s  %s\n' 4ed5754035b5e3b94a9049633173efbea6e380db87e899d121d50ec91ab584ef "$source_dir/libedit-socket.patch" | shasum -a 256 -c -
tar -xzf "$root/inputs/ios_system.tar.gz" --strip-components=1 -C "$root/core"
# Keep the pinned source's generated configure/Makefile inputs. Only its
# missing auxiliary scripts are supplied from the verified Automake release.
tar -xJf "$root/inputs/automake.tar.xz" --strip-components=1 -C "$root/automake"
for helper in compile install-sh missing depcomp; do
    rm -f "$source_dir/$helper"
    cp "$root/automake/lib/$helper" "$source_dir/$helper"
    chmod +x "$source_dir/$helper"
done
{
    printf 'Dash source: %s\nios_system source: %s\nRecipe commit: ' "$source_pin" "$core_pin"
    git -C "$repo" rev-parse HEAD
    xcodebuild -version
    clang --version
    echo "Automake helper source: 1.19 (archive checksum verified; no installed Autotools required)"
    xcrun --sdk iphoneos --show-sdk-version
    xcrun --sdk iphonesimulator --show-sdk-version
} > "$root/audit/source-toolchain.txt"

build_edit() (
    arch=$1
    sdk=$2
    out=$root/libedit-$sdk-$arch
    mkdir -p "$out"
    tar -xzf "$root/libedit-20260512-3.1.tar.gz" --strip-components=1 -C "$out"
    patch -s -t -F 0 -p1 -d "$out" < "$source_dir/libedit-socket.patch"
    mac_sdk=$(xcrun --sdk macosx --show-sdk-path)
    ios_sdk=$(xcrun --sdk "$sdk" --show-sdk-path)
    mkdir -p "$out/local"
    cp "$mac_sdk/usr/include/termcap.h" "$mac_sdk/usr/include/ncurses_dll.h" "$out/local/"
    target="$arch-apple-ios14.0"
    if [[ $sdk == iphonesimulator ]]; then target="$target-simulator"; fi
    flags="-Oz -target $target -isysroot $ios_sdk -I$out/local"
    cd "$out"
    nice -n 15 ./configure --build="$(bash "$out/config.guess")" --host="$arch-apple-ios" --disable-shared --enable-static --disable-readline CC=clang CFLAGS="$flags" CPPFLAGS="-I$out/local" LDFLAGS="-target $target -isysroot $ios_sdk" >configure.log 2>&1
    nice -n 15 make -C src -j2 >make.log 2>&1
    xcrun lipo -archs src/.libs/libedit.a

)

build_dash() (
    source_dir=$1
    output_dir=$2
    arch=$3
    sdk=$4
    runtime=$5
    edit_dir=$6
    mkdir -p "$output_dir"
    cd "$output_dir"
    sysroot=$(xcrun --sdk "$sdk" --show-sdk-path)
    hostroot=$(xcrun --sdk macosx --show-sdk-path)
    target="$arch-apple-ios14.0"
    if [[ $sdk == iphonesimulator ]]; then target="$target-simulator"; fi
    flags="-std=gnu17 -Oz -Wno-implicit-function-declaration -Wno-int-conversion -Wno-incompatible-function-pointer-types -target $target -isysroot $sysroot -DJOBS=0 -Dstat64=stat -Dlstat64=lstat -Dfstat64=fstat -DUSE_GLIBC_STDIO=1 -DFLUSHERR=1 -I$source_dir"
    link="-target $target -isysroot $sysroot -dynamiclib -F$runtime -framework ios_system"
    link="$link -L$edit_dir/src/.libs"
    # Select the patched header before the older copy in the Dash source root.
    flags="-I$edit_dir/src $flags"
    nice -n 15 "$source_dir/configure" CC=clang CXX=clang++ CC_FOR_BUILD="clang -std=gnu17 -isysroot $hostroot -DJOBS=0" CFLAGS="$flags" CPPFLAGS="$flags" CXXFLAGS="$flags" LDFLAGS="$link" LIBS=-lncurses ac_cv_func_strchrnul=no --build="$(bash "$edit_dir/config.guess")" --host="$arch-apple-ios" cross_compiling=yes --with-libedit >configure.log 2>&1
    nice -n 15 make -j2 >make.log 2>&1
    xcrun lipo -archs src/dash

)

for spec in iphoneos:arm64 iphonesimulator:arm64 iphonesimulator:x86_64; do
    sdk=${spec%:*}; arch=${spec#*:}
    core_out="$root/core-$sdk-$arch"
    rm -rf "$core_out" "$root/libedit-$sdk-$arch" "$root/dash-$sdk-$arch"
    mkdir -p "$core_out"
    nice -n 15 xcodebuild -project "$root/core/ios_system.xcodeproj" -target ios_system -configuration Release -sdk "$sdk" -arch "$arch" -jobs 2 CODE_SIGNING_ALLOWED=NO IPHONEOS_DEPLOYMENT_TARGET=14.0 CONFIGURATION_BUILD_DIR="$core_out" OBJROOT="$core_out/objects" SYMROOT="$core_out/products" > "$core_out/build.log" 2>&1
    build_edit "$arch" "$sdk"
    build_dash "$source_dir" "$root/dash-$sdk-$arch" "$arch" "$sdk" "$core_out" "$root/libedit-$sdk-$arch"
done
mkdir -p "$root/audit/core-simulator/ios_system.framework"
cp -R "$root/core-iphonesimulator-arm64/ios_system.framework/." "$root/audit/core-simulator/ios_system.framework/"
xcrun lipo -create "$root/core-iphonesimulator-arm64/ios_system.framework/ios_system" "$root/core-iphonesimulator-x86_64/ios_system.framework/ios_system" -output "$root/audit/core-simulator/ios_system.framework/ios_system"
xcodebuild -create-xcframework -framework "$root/core-iphoneos-arm64/ios_system.framework" -framework "$root/audit/core-simulator/ios_system.framework" -output "$root/audit/ios_system.xcframework"
(cd "$root/audit" && zip -qry ios_system.zip ios_system.xcframework)

out="$root/products"
for product in dash dashA dashB dashC dashD dashE; do
    for platform in iphoneos iphonesimulator; do
        framework="$out/$platform/$product.framework"
        mkdir -p "$framework"
        if [[ $platform == iphoneos ]]; then
            cp "$root/dash-iphoneos-arm64/src/dash" "$framework/$product"
            supported=iPhoneOS
        else
            xcrun lipo -create "$root/dash-iphonesimulator-arm64/src/dash" "$root/dash-iphonesimulator-x86_64/src/dash" -output "$framework/$product"
            supported=iPhoneSimulator
        fi
        xcrun install_name_tool -id "@rpath/$product.framework/$product" "$framework/$product"
        cat > "$framework/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>$product</string>
<key>CFBundleIdentifier</key><string>Nicolas-Holzschuch.$product</string>
<key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
<key>CFBundleName</key><string>$product</string>
<key>CFBundlePackageType</key><string>FMWK</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>CFBundleSupportedPlatforms</key><array><string>$supported</string></array>
<key>MinimumOSVersion</key><string>14.0</string>
</dict></plist>
PLIST
    done
    rm -rf "$out/$product.xcframework"
    xcodebuild -create-xcframework -framework "$out/iphoneos/$product.framework" -framework "$out/iphonesimulator/$product.framework" -output "$out/$product.xcframework" > "$out/$product-package.log" 2>&1
    (cd "$out" && zip -qry "$product.xcframework.zip" "$product.xcframework")
done
: > "$out/checksums.txt"
for product in dash dashA dashB dashC dashD dashE; do
    sum=$(swift package compute-checksum "$out/$product.xcframework.zip")
    printf '%s  %s\n' "$sum" "$product.xcframework.zip" >> "$out/checksums.txt"
    bash "$repo/ci/dash/audit-exports.sh" "$product" "$out/$product.xcframework.zip" "$root/audit/ios_system.zip" > "$out/$product.exports.txt"
done
{
    echo 'Dash frameworks: arm64 iOS and universal arm64/x86_64 Simulator, minimum iOS 14.'
    printf '\nDash source: `%s`; ios_system source: `%s`; libedit: `20260512-3.1` with the pinned socket patch.\n\n' "$source_pin" "$core_pin"
    echo 'The six products retain the published 259 exports and add the same 44 pinned-source exports. All ios_system-bound imports resolve against the source-built dependency. App callbacks described in SOCKET-INPUT.md remain an application integration requirement.'
    printf '\nChecksums:\n\n```text\n'
    cat "$out/checksums.txt"
    printf '```\n'
} > "$out/release.md"
