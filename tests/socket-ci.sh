#!/bin/bash
# Build the current Dash commit and run its public build/socket checks on Intel.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
logs=${1:-"$root/.build/socket-ci"}
mkdir -p "$logs"
logs=$(cd "$logs" && pwd)
if [[ $(uname -m) != x86_64 ]]; then
    echo 'This fixture requires an Intel iOS Simulator for the stock x86_64 Dash slice.' >&2
    exit 1
fi
work=$(mktemp -d "$logs/run.XXXXXX")
source="$work/source"
inputs="$logs/inputs"
mkdir -p "$source/.build" "$inputs"
git -C "$root" archive HEAD | tar -xf - -C "$source"

fetch() {
    local url=$1 digest=$2 path="$inputs/$3"
    if [[ ! -f $path ]]; then
        curl --fail --location --retry 3 "$url" --output "$path.download"
        printf '%s  %s\n' "$digest" "$path.download" | shasum -a 256 -c -
        mv "$path.download" "$path"
    fi
    printf '%s  %s\n' "$digest" "$path" | shasum -a 256 -c -
}
fetch 'https://github.com/demrom/ios_system/releases/download/ios-system-preview-2c560334ecca/ios_system.xcframework.zip' \
    bac0689c792901cbf410899162c06ab22a950b032adfb5f94b5c3ab6a661e883 ios_system.xcframework.zip
fetch 'https://github.com/demrom/ios_system/releases/download/ios-system-preview-2c560334ecca/files.xcframework.zip' \
    88a9f39c248e3ab05d1110d2e0a9f602dc5da16a6fc9191574dcaa7d121efaa2 files.xcframework.zip
fetch 'https://github.com/demrom/ios_system/releases/download/ios-system-preview-2c560334ecca/text.xcframework.zip' \
    e6851aae912cfd0dd5cdf99f24b06c35df26bd82f3ed81566add6e6802381e4d text.xcframework.zip
fetch 'https://github.com/holzschu/ios_system/releases/download/v3.0.5/shell.xcframework.zip' \
    855ff9b12bfbbdbd5298324377d91e18e6ac97dbb19d3c9311ce5a023ee51b2e shell.xcframework.zip
fetch 'https://raw.githubusercontent.com/holzschu/ios_system/f187d27373865977db4705b38d3a35eec13415ec/Resources/commandDictionary.plist' \
    7911fe0e7b1a9eb2c1ba761fe728fc3ede50093d29beb9735c0d8bb4201100b3 commandDictionary.plist
fetch 'https://thrysoee.dk/editline/libedit-20260512-3.1.tar.gz' \
    432d5e7ea8b0116dd39f2eca7bc11d0eed77faa6b77ea526ace89907c23ea4a0 libedit.tar.gz
fetch 'https://ftp.gnu.org/gnu/ncurses/ncurses-6.6.tar.gz' \
    355b4cbbed880b0381a04c46617b7656e362585d52e9cf84a67e2009b749ff11 ncurses.tar.gz

ditto -x -k "$inputs/ios_system.xcframework.zip" "$source"
cd "$source/.build"
tar -xf "$inputs/libedit.tar.gz"
tar -xf "$inputs/ncurses.tar.gz"
edit_source="$PWD/libedit-20260512-3.1"
ncurses_source="$PWD/ncurses-6.6"
patch -d "$edit_source" -p1 < "$source/libedit-socket.patch"
build=$(sh "$ncurses_source/config.guess")
namespace='-Dtgetent=dash_tgetent -Dtgetflag=dash_tgetflag -Dtgetnum=dash_tgetnum -Dtgetstr=dash_tgetstr -Dtgoto=dash_tgoto -Dtputs=dash_tputs'
# Use host terminfo tools from the same source as the target archives.
mkdir host-ncurses
(
    cd host-ncurses &&
    "$ncurses_source/configure" --without-shared --without-debug --without-ada \
        --without-cxx --without-cxx-binding --without-manpages --without-tests &&
    make -j4
) > "$work/host-ncurses.log" 2>&1 || { tail -60 "$work/host-ncurses.log" >&2; exit 1; }
tic="$PWD/host-ncurses/progs/tic"
infocmp="$PWD/host-ncurses/progs/infocmp"
test -x "$tic"
test -x "$infocmp"
for sdk in iphoneos iphonesimulator; do
    case "$sdk" in
        iphoneos) target=arm64-apple-ios15.0; host=armv8-apple-darwin; suffix= ;;
        iphonesimulator) target=x86_64-apple-ios15.0-simulator; host=x86_64-apple-darwin; suffix=_sim ;;
    esac
    flags="-target $target -isysroot $(xcrun --sdk "$sdk" --show-sdk-path)"
    tinfo="$PWD/tinfo$suffix"
    edit="$PWD/libedit$suffix"
    mkdir -p "$tinfo" "$edit"
    (
        cd "$tinfo" &&
        "$ncurses_source/configure" --build="$build" --host="$host" \
            --with-build-cc=clang --with-termlib --with-ospeed=speed_t --disable-widec --disable-mixed-case \
            --disable-database --with-fallbacks=xterm-256color,xterm,vt100 \
            --with-tic-path="$tic" --with-infocmp-path="$infocmp" \
            --without-shared --without-debug --without-ada --without-cxx --without-cxx-binding \
            --without-manpages --without-progs --without-tests --disable-db-install \
            CC=clang CFLAGS="$flags -O2 $namespace" CPPFLAGS="$flags" LDFLAGS="$flags" LIBS= &&
        make -C include -j4 &&
        make -C ncurses -j4 ../lib/libtinfo.a
    ) > "$work/tinfo-$sdk.log" 2>&1 || { tail -60 "$work/tinfo-$sdk.log" >&2; exit 1; }
    (
        cd "$edit" &&
        ac_cv_lib_ncurses_tgetent=no ac_cv_lib_curses_tgetent=no \
            ac_cv_lib_termcap_tgetent=no ac_cv_lib_tinfo_tgetent=yes \
            "$edit_source/configure" --build="$build" --host="$host" \
            --disable-shared --enable-static --disable-examples CC=clang CFLAGS="$flags -O2" \
            CPPFLAGS="$flags -I$tinfo/include $namespace" LDFLAGS="$flags -L$tinfo/lib" LIBS= &&
        make -C src -j4
    ) > "$work/libedit-$sdk.log" 2>&1 || { tail -60 "$work/libedit-$sdk.log" >&2; exit 1; }
done
cd "$source"
sh autogen.sh
sh build_dash.sh > "$work/build-dash.log" 2>&1 || { tail -60 "$work/build-dash.log" >&2; exit 1; }
for name in dash dashA dashB dashC dashD dashE; do test -f "$source/$name.xcframework.zip"; done

failed=0
sh "$source/tests/frameworks.sh" "$source" 2>&1 | tee "$work/frameworks.log" || failed=1
sh "$source/tests/strchrnul-availability.sh" "$source/build" 2>&1 | tee "$work/strchrnul-availability.log" || failed=1
probe="$work/probe"
mkdir -p "$probe/Frameworks"
cp -R "$source/ios_system.xcframework/ios-arm64_x86_64-simulator/ios_system.framework" "$probe/Frameworks/"
for name in files text shell; do
    ditto -x -k "$inputs/$name.xcframework.zip" "$work"
    cp -R "$work/$name.xcframework/ios-arm64_x86_64-simulator/$name.framework" "$probe/Frameworks/"
done
for name in dash dashA dashB dashC dashD dashE; do
    cp -R "$source/build/Release-iphonesimulator/$name.framework" "$probe/Frameworks/"
done
cp "$inputs/commandDictionary.plist" "$probe/"
# The standalone ios_system catalogue has no Dash registration. Use the
# app's normal command metadata for the nested login-profile invocation.
plutil -insert dash -json '["dash.framework/dash","main","efIimnsxvVECabu","no"]' "$probe/commandDictionary.plist"
# Match the ordinary a-Shell bundle's registry and executable PATH markers.
plutil -insert sleep -json '["shell.framework/shell","sleep_main","","none"]' "$probe/commandDictionary.plist"
mkdir "$probe/bin"
for command in cat dash ls rm sh sleep; do
    touch "$probe/bin/$command"
    chmod +x "$probe/bin/$command"
done
cp "$source/tests/descriptor-lifetime.sh" "$probe/"
dash="$probe/Frameworks/dash.framework/dash"
for framework in "$probe"/Frameworks/*.framework; do codesign --force --sign - "$framework"; done
for name in socket-input pipelines input-lifetime login-profile environment-reentry descriptor-lifetime; do
    xcrun --sdk iphonesimulator clang -target x86_64-apple-ios15.0-simulator -fobjc-arc -Wall -Wextra -Wno-unused-parameter \
        -DNDEBUG -F"$probe/Frameworks" -framework ios_system -framework Foundation -Wl,-rpath,@executable_path/Frameworks \
        -Wl,-export_dynamic "$source/tests/$name.m" -o "$probe/$name"
    codesign --force --sign - "$probe/$name"
done

model=com.apple.CoreSimulator.SimDeviceType.iPhone-17
runtime=$(xcrun simctl list runtimes -j | jq -r --arg model "$model" \
    '[.runtimes[] | select(.isAvailable and (.identifier | contains("iOS")) and (.version | startswith("26.")) and any(.supportedDeviceTypes[]?; .identifier == $model))] | sort_by(.version | split(".") | map(tonumber)) | last.identifier // empty')
if [[ -z $runtime ]]; then
    echo 'No available iOS 26 runtime supports iPhone 17' >&2
    exit 1
fi
device=$(xcrun simctl create Dash-Socket-Input "$model" "$runtime")
trap 'xcrun simctl shutdown "$device" || true; xcrun simctl delete "$device"' EXIT
xcrun simctl boot "$device"
xcrun simctl bootstatus "$device" -b
run() {
    local label=$1 name=$2 status=0
    shift 2
    /usr/bin/time -p xcrun simctl spawn "$device" "$probe/$name" "$@" > "$work/$label.log" 2>&1 || status=$?
    printf 'exit=%s\n' "$status" >> "$work/$label.log"
    if [[ $status == 0 ]]; then
        printf 'Dash probe %s: PASS\n' "$label"
    else
        printf 'Dash probe %s: FAIL (exit %d)\n' "$label" "$status" >&2
        tail -60 "$work/$label.log" >&2
        failed=1
    fi
}
for scenario in line context foreground delete forward-delete raw cancel nested-cancel resize repeat; do
    run "socket-$scenario" socket-input "$dash" "$scenario"
done
for scenario in group early-reader heredoc subshell-next subshell-status wasm-producer-eof wasm-producer-fails \
    wasm-consumer-skips pipeline-environment command-consumer pipeline-error-unwind pipeline-error-next \
    unset-semantics unset-environment; do
    run "pipeline-$scenario" pipelines "$dash" "$scenario"
done
for scenario in borrowed script stdout-alias stderr-dup; do
    run "input-$scenario" input-lifetime "$dash" "$scenario"
done
run login-profile login-profile
run descriptor-lifetime descriptor-lifetime "$probe/descriptor-lifetime.sh" "$dash"
if ! grep -Fxq DESCRIPTOR_LIFETIME_PASS "$work/descriptor-lifetime.log"; then
    echo 'Dash descriptor-lifetime script did not finish its checks' >&2
    failed=1
fi

# Re-link the same objects with the README's interposition option. The
# environment fixture supplies the embedding host's environmentVariables.
printf 'LDFLAGS += -Wl,-flat_namespace\n' > "$work/flat-namespace.mk"
mv "$source/src/dash" "$work/dash-before-relink"
make -C "$source/src" -f Makefile -f "$work/flat-namespace.mk" dash > "$work/flat-namespace.log" 2>&1 || {
    tail -60 "$work/flat-namespace.log" >&2
    exit 1
}
codesign --force --sign - "$source/src/dash"
run environment-reentry environment-reentry "$source/src/dash"
exit "$failed"
