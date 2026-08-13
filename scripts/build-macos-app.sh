#!/bin/sh
set -eu

fail() {
    echo "error: $*" >&2
    exit 1
}

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        fail "required command not found: $1"
    fi
}

require_executable() {
    if [ ! -x "$1" ]; then
        fail "required executable not found: $1"
    fi
}

require_file() {
    if [ ! -f "$1" ]; then
        fail "required file not found: $1"
    fi
}

require_nonempty_file() {
    if [ ! -s "$1" ]; then
        fail "build artifact is missing or empty: $1"
    fi
}

has_rpath() {
    /usr/bin/otool -l "$1" | /usr/bin/awk -v expected="$2" '
        $1 == "cmd" && $2 == "LC_RPATH" {
            reading_rpath = 1
            next
        }
        reading_rpath && $1 == "path" {
            path = $0
            sub(/^[[:space:]]*path /, "", path)
            sub(/ \(offset [0-9]+\)$/, "", path)
            if (path == expected) {
                found = 1
            }
            reading_rpath = 0
        }
        END { exit found ? 0 : 1 }
    '
}

links_library() {
    /usr/bin/otool -L "$1" | /usr/bin/awk -v expected="$2" '
        NR > 1 {
            library = $0
            sub(/^[[:space:]]*/, "", library)
            sub(/ \(compatibility version.*$/, "", library)
            if (library == expected) {
                found = 1
            }
        }
        END { exit found ? 0 : 1 }
    '
}

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
macos_package_directory="$repository_root/frontends/macos"
info_plist="$macos_package_directory/Resources/Info.plist"
rust_library_directory="$repository_root/target/release"
rust_library="$rust_library_directory/liblibchess_ffi.dylib"

# Keep all Swift caches, products, staging data, and the assembled app in one
# initialized root. CI can override the default with LIBCHESS_BUILD_DIR.
build_directory=${LIBCHESS_BUILD_DIR:-"$repository_root/.build"}
case "$build_directory" in
    /*) ;;
    *) build_directory="$repository_root/$build_directory" ;;
esac

if [ "$(uname -s)" != "Darwin" ]; then
    fail "the macOS app can only be built on macOS"
fi

require_command cargo
require_executable /usr/bin/xcrun
require_executable /usr/bin/codesign
require_executable /usr/bin/install_name_tool
require_executable /usr/bin/otool
require_executable /usr/bin/plutil
require_executable /usr/bin/file
require_executable /usr/bin/mktemp

if [ -n "${DEVELOPER_DIR:-}" ]; then
    if [ ! -d "$DEVELOPER_DIR" ]; then
        fail "DEVELOPER_DIR does not exist: $DEVELOPER_DIR"
    fi
elif [ -d /Applications/Xcode.app/Contents/Developer ]; then
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    export DEVELOPER_DIR
fi

if ! /usr/bin/xcrun --find swift >/dev/null 2>&1; then
    fail "Swift was not found through xcrun; install or select a compatible Xcode toolchain"
fi
if ! /usr/bin/xcrun --sdk macosx --show-sdk-path >/dev/null 2>&1; then
    fail "the macOS SDK was not found through xcrun"
fi
if ! cargo --version >/dev/null 2>&1; then
    fail "Cargo is installed but could not run"
fi

require_file "$repository_root/Cargo.toml"
require_file "$repository_root/Cargo.lock"
require_file "$macos_package_directory/Package.swift"
require_file "$info_plist"
if ! /usr/bin/plutil -lint "$info_plist" >/dev/null; then
    fail "invalid Info.plist: $info_plist"
fi

/bin/mkdir -p "$build_directory"
build_directory=$(CDPATH= cd -- "$build_directory" && pwd)
if [ "$build_directory" = "/" ] || [ "$build_directory" = "$repository_root" ]; then
    fail "LIBCHESS_BUILD_DIR must name a dedicated build directory"
fi

swift_module_cache="$build_directory/swift-module-cache"
clang_module_cache="$build_directory/clang-module-cache"
swift_cache="$build_directory/swift-cache"
swift_config="$build_directory/swift-config"
swift_security="$build_directory/swift-security"
swift_scratch="$build_directory/swift-products"
swift_binary="$swift_scratch/release/LibChessMac"
app_directory="$build_directory/LibChess.app"

/bin/mkdir -p \
    "$swift_module_cache" \
    "$clang_module_cache" \
    "$swift_cache" \
    "$swift_config" \
    "$swift_security" \
    "$swift_scratch"

write_probe="$build_directory/.libchess-write-test.$$"
if ! (umask 077 && : > "$write_probe"); then
    fail "build directory is not writable: $build_directory"
fi
/bin/rm -f "$write_probe"

staging_root=""
previous_app_directory=""
cleanup() {
    if [ -n "$previous_app_directory" ] \
        && { [ -e "$previous_app_directory" ] || [ -L "$previous_app_directory" ]; } \
        && { [ ! -e "$app_directory" ] && [ ! -L "$app_directory" ]; }; then
        if ! /bin/mv "$previous_app_directory" "$app_directory"; then
            echo "error: could not restore the previous generated app bundle" >&2
        fi
    fi
    if [ -n "$staging_root" ] && [ -d "$staging_root" ]; then
        /bin/rm -rf "$staging_root"
    fi
}
trap cleanup 0
trap 'exit 129' 1
trap 'exit 130' 2
trap 'exit 143' 15

echo "Building libchess-ffi (release)..."
(
    cd "$repository_root"
    cargo build --locked --release --package libchess-ffi
)

echo "Building LibChessMac (release)..."
(
    cd "$macos_package_directory"
    SWIFTPM_MODULECACHE_OVERRIDE="$swift_module_cache" \
    CLANG_MODULE_CACHE_PATH="$clang_module_cache" \
    /usr/bin/xcrun swift build --configuration release \
        --scratch-path "$swift_scratch" \
        --cache-path "$swift_cache" \
        --config-path "$swift_config" \
        --security-path "$swift_security"
)

require_nonempty_file "$rust_library"
require_nonempty_file "$swift_binary"
if [ ! -x "$swift_binary" ]; then
    fail "Swift build artifact is not executable: $swift_binary"
fi

case "$(/usr/bin/file -b "$rust_library")" in
    *Mach-O*) ;;
    *) fail "Rust build artifact is not a Mach-O library: $rust_library" ;;
esac
case "$(/usr/bin/file -b "$swift_binary")" in
    *Mach-O*) ;;
    *) fail "Swift build artifact is not a Mach-O executable: $swift_binary" ;;
esac

staging_root=$(/usr/bin/mktemp -d "$build_directory/.libchess-app.XXXXXX")
staging_app_directory="$staging_root/LibChess.app"
staging_contents_directory="$staging_app_directory/Contents"
staging_macos_directory="$staging_contents_directory/MacOS"
staging_frameworks_directory="$staging_contents_directory/Frameworks"
packaged_executable="$staging_macos_directory/LibChessMac"
packaged_library="$staging_frameworks_directory/liblibchess_ffi.dylib"

/bin/mkdir -p "$staging_macos_directory" "$staging_frameworks_directory"
/bin/cp "$swift_binary" "$packaged_executable"
/bin/chmod 755 "$packaged_executable"
/bin/cp "$rust_library" "$packaged_library"
/bin/chmod 755 "$packaged_library"
/bin/cp "$info_plist" "$staging_contents_directory/Info.plist"

if ! /usr/bin/plutil -lint "$staging_contents_directory/Info.plist" >/dev/null; then
    fail "packaged Info.plist is invalid"
fi
if ! links_library "$packaged_executable" "@rpath/liblibchess_ffi.dylib"; then
    fail "packaged executable does not link liblibchess_ffi.dylib through @rpath"
fi

# SwiftPM needs the development library directory while linking. The packaged
# executable must use the library embedded in its own Frameworks directory so
# Finder does not trigger privacy checks for a path inside the source checkout.
if has_rpath "$packaged_executable" "$rust_library_directory"; then
    /usr/bin/install_name_tool -delete_rpath \
        "$rust_library_directory" \
        "$packaged_executable"
fi
if has_rpath "$packaged_executable" "$rust_library_directory"; then
    fail "source-checkout rpath remained in the packaged executable"
fi
if ! has_rpath "$packaged_executable" "@executable_path/../Frameworks"; then
    fail "packaged executable is missing its embedded Frameworks rpath"
fi

echo "Signing and verifying LibChess.app..."
/usr/bin/codesign --force --sign - "$packaged_library"
/usr/bin/codesign --force --deep --sign - "$staging_app_directory"
/usr/bin/codesign --verify --deep --strict "$staging_app_directory"

previous_app_directory="$staging_root/Previous-LibChess.app"
if [ -e "$app_directory" ] || [ -L "$app_directory" ]; then
    if ! /bin/mv "$app_directory" "$previous_app_directory"; then
        fail "could not move the previous generated app bundle out of the way"
    fi
fi
if ! /bin/mv "$staging_app_directory" "$app_directory"; then
    if [ -e "$previous_app_directory" ] || [ -L "$previous_app_directory" ]; then
        if ! /bin/mv "$previous_app_directory" "$app_directory"; then
            fail "could not install the new app or restore the previous generated app"
        fi
    fi
    fail "could not install the generated app bundle"
fi

/usr/bin/codesign --verify --deep --strict "$app_directory"

cleanup
trap - 0 1 2 15

echo "Built and verified LibChess.app:"
echo "$app_directory"
