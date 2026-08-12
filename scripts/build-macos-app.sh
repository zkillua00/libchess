#!/bin/sh
set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
swift_module_cache="$repository_root/.build/swift-module-cache"
clang_module_cache="$repository_root/.build/clang-module-cache"
swift_cache="$repository_root/.build/swift-cache"
swift_config="$repository_root/.build/swift-config"
swift_security="$repository_root/.build/swift-security"
app_directory="$repository_root/.build/LibChess.app"
contents_directory="$app_directory/Contents"
macos_directory="$contents_directory/MacOS"
frameworks_directory="$contents_directory/Frameworks"

if [ -d /Applications/Xcode.app/Contents/Developer ]; then
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    export DEVELOPER_DIR
fi

cd "$repository_root"
cargo build --release --package libchess-ffi

cd "$repository_root/frontends/macos"
SWIFTPM_MODULECACHE_OVERRIDE="$swift_module_cache" \
CLANG_MODULE_CACHE_PATH="$clang_module_cache" \
/usr/bin/xcrun swift build --configuration release \
    --cache-path "$swift_cache" \
    --config-path "$swift_config" \
    --security-path "$swift_security"

mkdir -p "$macos_directory" "$frameworks_directory"
cp "$repository_root/frontends/macos/.build/release/LibChessMac" \
    "$macos_directory/LibChessMac"
cp "$repository_root/target/release/liblibchess_ffi.dylib" \
    "$frameworks_directory/liblibchess_ffi.dylib"
cp "$repository_root/frontends/macos/Resources/Info.plist" \
    "$contents_directory/Info.plist"

codesign --force --sign - "$frameworks_directory/liblibchess_ffi.dylib"
codesign --force --deep --sign - "$app_directory"

echo "$app_directory"

