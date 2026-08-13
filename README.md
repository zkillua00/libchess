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
- `crates/libchess-rules`: provider-neutral legal positions and move generation
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

## Create a bot game

After connecting, the macOS app can create a casual game against a bot
advertised by the active provider. Lichess currently advertises its eight AI
levels and the complete AI-challenge option set:

- Standard, Chess960, Crazyhouse, Antichess, Atomic, Horde, King of the Hill,
  Racing Kings, Three-check, and From Position
- every accepted initial clock value: 0, 15, 30, 45, 60, or 90 seconds, then
  every whole minute from 2 through 180; and every increment from 0 through 60
  seconds, subject to the Board API's Blitz-or-slower restriction
- correspondence controls of 1, 2, 3, 5, 7, 10, or 14 days per move
- unlimited games
- White, Black, or random color
- optional X-FEN positions for Standard and Chess960, and required X-FEN for
  From Position

Choose the settings, then select **Create Game**. Lichess AI games are always
casual, so rated play is not a missing frontend option. The app enters its
native board as soon as the game is created. It supports legal click-to-move,
promotions, Chess960 castling, Crazyhouse pockets and drops, clocks, move
history, draw and takeback offers, abort, resign, and disconnect recovery.

Lichess live play is an authenticated streaming HTTP connection carrying
newline-delimited JSON, not a WebSocket. The provider adapter consumes that
transport and emits provider-neutral immutable game snapshots through the C
ABI. The SwiftUI frontend never parses Lichess payloads or decides move
legality. Moves and game actions travel back through independent commands so
the live stream remains open while the player acts.

The frontend sends opaque opponent and variant identifiers plus a normalized
time-control value through the shared C ABI. It does not encode Lichess's
numeric levels, variant keys, ranges, or correspondence intervals. This leaves
a future Chess.com adapter free to advertise named bot personalities and a
different supported option set through the same contract.

No license has been selected yet. `libchess-rules` currently depends on
Shakmaty, which is distributed under GPL-3.0-or-later, so choose a compatible
project/distribution license or replace that dependency before publishing.
