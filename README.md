# LibChess

LibChess is an open-source, native chess client foundation. Rust owns the
platform-independent chess application layer; each operating system gets a
native user interface.

The native frontends are macOS with SwiftUI and Windows with WinUI 3 and
C++/WinRT. Linux with Qt is intended to consume the same Rust library through
its stable C ABI. Lichess is the first online provider. A future Chess.com
provider can be added without changing the frontend contract.

## Repository layout

- `crates/libchess-core`: domain types, provider ports, and safety policy
- `crates/libchess-board`: portable board assets, themes, metrics, and motion
- `crates/libchess-rules`: provider-neutral legal positions and move generation
- `crates/libchess-lichess`: Lichess HTTP adapter
- `crates/libchess`: provider registry and application service
- `crates/libchess-ffi`: small, versioned C ABI for native frontends
- `frontends/macos`: SwiftUI app and its Swift wrapper
- `frontends/windows`: WinUI 3 app and its C++/WinRT wrapper
- `docs/architecture.md`: boundaries and extension rules

## Build on macOS

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

## Build on Windows

The Windows frontend is a native, unpackaged WinUI 3 desktop application. From
a PowerShell prompt with Visual Studio 2022 C++ tools and Rust installed, run:

```powershell
.\scripts\build-windows-app.ps1
```

Add `-Configuration Debug` for a debug build or `-Run` to launch after a
successful build. The script restores the pinned Windows App SDK and C++/WinRT
packages, builds the Rust DLL, builds the native executable, and places both in
the same output directory. See [`frontends/windows/README.md`](frontends/windows/README.md)
for the current Windows feature boundary.

## Lichess sign-in

The macOS and Windows apps use Lichess OAuth Authorization Code with PKCE.
Choose **Sign in with Lichess**, approve the narrowly fixed `board:play` scope
in the system browser, and Lichess returns through the native callback registered
for that platform. The Rust adapter creates and validates the PKCE transaction
and exchanges the one-time code. macOS stores the validated access token in
Keychain; Windows stores it in the current user's Windows Credential Manager.

A provisioned, stably signed build uses the macOS data-protection Keychain with
`AfterFirstUnlockThisDeviceOnly`, which keeps the token available to background
work after the first device unlock without synchronizing it to another device.
The ad-hoc local bundle has no provisioning profile, so it can only fall back to
the legacy file-based Keychain; an inaccessible legacy item is ignored rather
than prompting, and signing in once replaces it when secure persistence is
available.

The callback scheme and OAuth client identifier are tied to the macOS bundle
identifier, `org.libchess.macos`. A distributable fork should choose its own
bundle identifier and update `LichessOAuth` plus `Info.plist` together.

The unpackaged Windows build registers `org.libchess.windows` for the current
user through Windows App Lifecycle. Its callback is redirected to the original
single app instance so the pending verifier never leaves Rust. The registration
is refreshed to the current executable path on launch; a production installer
should remove it during uninstall.

The release builds use the operating system browser and native credential
storage rather than embedding web authentication.

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
Piece movement, captures, promotions, castling, rollbacks, and board resizing
use rules supplied by the Rust board provider and translated into native
SwiftUI transitions that respect Reduce Motion. The Board Appearance menu
selects board and piece themes independently. Built-in boards are Classic,
Slate, Walnut, Ocean, Charcoal, and Rosewood; piece sets are System Solid,
System Outline, CC0 Silhouette, and Notation. Compact, Small, Medium, Large, and
Maximum zoom levels are provider-advertised as well. These assets, palettes,
geometry values, animation rules, and zoom presets are not defined in Swift,
so future WinUI 3 and Qt frontends can consume the same customization contract.
The vector Silhouette pieces come from a
[CC0 release by femrek](https://opengameart.org/content/chess-pieces-in-svg-format),
with provenance and checksums retained beside the embedded SVG files.

LibChess Settings (`Command-,`) manages user themes without moving theme policy
into Swift. A custom board theme stores only a palette, base board, and portable
hue/saturation/brightness adjustment, so it never owns piece assets. A custom
piece theme can inherit an installed set or register a folder containing six
self-contained SVG files. LibChess validates, combines, and serializes these
definitions; the native frontend persists the versioned snapshot and restores
it from an atomically written Application Support file at startup.

## Recent games and analysis

The **Recent Games** sidebar destination pages through the connected provider's
finished games newest-first. A single click opens a native review workspace in
the LibChess window. It includes an animated replay board, keyboard and button
navigation, SAN move selection, opening metadata, an evaluation chart, best
lines, and inaccuracy, mistake, and blunder judgments whenever the provider has
computer analysis for the game. Opening the original game on the provider is an
explicit secondary action and never happens just because a history row was
selected.

Review data and export payloads come from the active provider through the
shared Rust contract. Lichess SAN is normalized into provider-neutral move IDs
in Rust, and every reviewed position is reconstructed by `libchess-rules`; the
SwiftUI frontend does not parse provider JSON or calculate board state. Export
controls live in the review toolbar. Lichess exports include clocks, opening
data, existing evaluations, and literate annotations when available, and the
native save panel writes the result as a `.pgn` file.

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

## License

LibChess is licensed under the GNU General Public License, version 3 or any
later version (`GPL-3.0-or-later`). See [LICENSE](LICENSE).

The chess piece silhouettes under
`crates/libchess-board/assets/cc0-silhouette` remain available under CC0 1.0;
their provenance and license details are documented alongside the assets.
