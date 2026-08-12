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

The current machine only has Apple Command Line Tools selected. The Swift
package can still be compiled, but creating, signing, and distributing a normal
`.app` bundle requires the full Xcode installation.

For this bootstrap slice, the macOS screen accepts a Lichess personal access
token with the `board:play` scope and keeps it in Keychain. Public releases
will use Lichess OAuth Authorization Code + PKCE instead of asking users for a
token.

No license has been selected yet. Add one before publishing the repository.
