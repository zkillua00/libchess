#!/bin/sh
set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
swift_module_cache="$repository_root/.build/swift-module-cache"
clang_module_cache="$repository_root/.build/clang-module-cache"
swift_cache="$repository_root/.build/swift-cache"
swift_config="$repository_root/.build/swift-config"
swift_security="$repository_root/.build/swift-security"

if [ -d /Applications/Xcode.app/Contents/Developer ]; then
    DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
    export DEVELOPER_DIR
fi

cd "$repository_root"
cargo fmt --all --check
cargo test --workspace
cargo clippy --workspace --all-targets -- -D warnings
cargo build --release --package libchess-ffi

cd "$repository_root/frontends/macos"
SWIFTPM_MODULECACHE_OVERRIDE="$swift_module_cache" \
CLANG_MODULE_CACHE_PATH="$clang_module_cache" \
/usr/bin/xcrun swift build \
    --cache-path "$swift_cache" \
    --config-path "$swift_config" \
    --security-path "$swift_security"
