# LibChess

LibChess is an open-source, native chess client foundation. Rust owns the
platform-independent chess application layer; each operating system gets a
native user interface.

The first frontend is macOS with SwiftUI. Windows with WinUI 3 and Linux with
Qt are intended to consume the same Rust library through its stable C ABI.
Lichess is the first online provider. A future Chess.com provider can be added
without changing the frontend contract.

## Repository layout

- `crates/libchess-core`: domain types, provider ports, and safety policy
- `crates/libchess-lichess`: Lichess HTTP adapter
- `crates/libchess`: provider registry and application service
- `crates/libchess-ffi`: small, versioned C ABI for native frontends
- `frontends/macos`: SwiftUI app and its Swift wrapper
- `docs/architecture.md`: boundaries and extension rules

## Build the first macOS slice

The Rust tests and library can be built with:

```sh
cargo test --workspace
cargo build --release --package libchess-ffi
```

Then build the SwiftUI executable:

```sh
cd frontends/macos
swift build
```

Or assemble an ad-hoc-signed local app bundle containing the Rust dynamic
library:

```sh
./scripts/build-macos-app.sh
open .build/LibChess.app
```

## Lichess sign-in

The macOS app uses Lichess OAuth Authorization Code with PKCE. Choose **Sign in
with Lichess**, approve the narrowly fixed `board:play` scope in the system
browser, and Lichess returns to the app through
`org.libchess.macos://oauth/lichess`. The Rust adapter creates and validates the
PKCE transaction and exchanges the one-time code. The macOS wrapper stores the
validated access token in Keychain.

The callback scheme and OAuth client identifier are tied to the macOS bundle
identifier, `org.libchess.macos`. A distributable fork should choose its own
bundle identifier and update `LichessOAuth` plus `Info.plist` together.

The release build is deliberately small: the app links the Rust library as a
single dynamic library and uses the operating system browser and Keychain.

No license has been selected yet. Add one before publishing the repository.
