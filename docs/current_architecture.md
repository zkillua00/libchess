# Current Architecture

This document describes the implementation that exists in the repository as of
2026-08-17. [`architecture.md`](architecture.md) remains the longer-term design
and portability contract; this file records the current runtime, platform
integration, implemented providers, and known boundaries.

## Implementation status

| Area | Current implementation | Not implemented yet |
| --- | --- | --- |
| Native frontends | macOS 14+ using AppKit and SwiftUI; Windows 10 2004+ using WinUI 3 and C++/WinRT, with equivalent current product surfaces | Qt and a Linux frontend |
| Chess backends | Lichess and a discovered local Stockfish UCI engine | Chess.com and other platform or engine adapters |
| Game creation | Lichess computer games and private local Stockfish games | Human challenges and matchmaking |
| Live play | Multiple normalized online or local games, prediction, clocks, and game actions | Persistent local sessions across app restarts |
| Analysis | Native provider review plus local Stockfish post-game evaluation | A general interactive analysis-board command set |
| Board presentation | Built-in and user-defined board and piece themes | Downloadable provider or theme packages |
| Distribution | Locally assembled macOS app bundle and unpackaged self-contained Windows build | Production signing, notarization, and installers |

`ClientBuilder::with_builtin_providers()` registers `LichessFactory`,
`StockfishFactory`, and `BuiltinBoardProvider`. The Stockfish factory discovers
and probes a real UCI executable at startup; on this development machine the
discovered engine reports itself as Stockfish 18. An undiscoverable engine stays
in the launcher as an unavailable backend with a backend-supplied explanation.
Chess.com and Linux remain extension points rather than code currently shipped
by this repository. Windows now covers the same current launcher, account,
gameplay, history/review, appearance, and floating-board product areas as macOS
using Windows-native interaction patterns.

## Runtime topology

```text
macOS process
|
+-- AppKit application lifecycle
|   +-- fixed-size floating launcher NSPanel
|   |   `-- SwiftUI backend selection and OAuth status
|   +-- authenticated workspace NSWindow
|   |   `-- SwiftUI ContentView / game workspace
|   +-- settings NSWindow
|   |   `-- SwiftUI settings views
|   `-- floating borderless NSPanel
|       `-- SwiftUI chessboard only
|
+-- LibChessKit
|   +-- @MainActor LibChessStore
|   +-- Codable wire models
|   +-- native board-presentation mapping
|   +-- Keychain credential storage
|   `-- Application Support customization storage
|
+-- CLibChess C bridge
|   `-- version 1 JSON commands and events
|
`-- liblibchess_ffi.dylib
    +-- one Rust worker thread and current-thread Tokio runtime
    +-- libchess orchestration and provider registry
    +-- libchess-core shared contracts
    +-- libchess-rules position reconstruction
    +-- libchess-board board and piece presentation
    +-- libchess-lichess authenticated HTTP and NDJSON streams
    |   `-- lichess.org
    `-- libchess-stockfish local-game and review adapter
        `-- persistent UCI child process per active local game
```

```text
Windows process
|
+-- Windows App SDK / WinUI 3 application lifecycle
|   +-- native XAML launcher and NavigationView workspace
|   `-- titleless floating-board utility window
+-- C++/WinRT wire models and ABI wrapper
|   +-- DispatcherQueue handoff to the UI thread
|   +-- Windows Credential Manager token storage
|   `-- registry and Local AppData presentation persistence
`-- libchess_ffi.dll
    `-- the same Rust worker, providers, rules, and board presentation
```

The native frontend owns windows, menus, dialogs, operating-system storage,
accessibility adaptation, and rendering. Rust owns backend discovery and
selection, provider networking, engine processes, response parsing, chess rules,
normalized application models, and portable board-presentation policy.

Backend selection is provider-neutral. Rust descriptors carry the backend kind,
display copy, semantic icon, availability, action title, connection method,
OAuth configuration, capabilities, opponent catalog, and game-creation defaults.
Each frontend lists and renders those values and sends the selected opaque
backend ID. Platform presentation code maps the backend's semantic icon to an
SF Symbol or Segoe Fluent icon; provider facts and identifiers are not encoded
in either launcher.

## Rust workspace

### `libchess-core`

`libchess-core` contains shared value types and traits. It defines:

- backend descriptors, kinds, connection methods, semantic icons, availability,
  capability identifiers, and backend-owned creation defaults;
- accounts, OAuth configuration, bot-game options, game history, export, and
  review models;
- normalized live-game state, clocks, players, chat, legal moves, game actions,
  and event sinks;
- board-provider, board-theme, piece-theme, motion, asset, palette, and zoom
  contracts;
- validation and error types used on both sides of every provider adapter.

The `PlatformBackend` trait provides account lookup, bot-game creation, live
game catalogs and streams, history, PGN export, game review, move submission,
and game actions. Both remote services and local engines use this normalized
session contract. Its default methods report an unsupported capability, so a
backend implements only the operations it advertises. A factory can construct
an authenticated backend from a token or a credential-free local backend.

The crate also exposes `ensure_engine_allowed`, which rejects both rated and
casual online contexts. The local Stockfish adapter never attaches an engine to
an online game: it owns separate local sessions and only analyses their finished
positions.

### `libchess-rules`

`libchess-rules` reconstructs an authoritative board from an initial FEN and a
provider-normalized move list. It produces pieces, pockets, side to move, check
state, last move, move history, and provider-ready legal move identifiers.

The implemented variants are Standard, Chess960, Crazyhouse, Antichess, Atomic,
Horde, King of the Hill, Racing Kings, Three-check, and From Position. The same
rules path is used for live snapshots, predicted moves, and review positions.
It also converts normalized UCI move lists to SAN for locally generated PGN.
The native frontend does not contain a second move generator.

### `libchess-board`

`libchess-board` implements `BuiltinBoardProvider`. It supplies the Classic,
Slate, Walnut, Ocean, Charcoal, and Rosewood board themes and the System Solid,
System Outline, CC0 Silhouette, and Notation piece themes.

Board themes and piece themes are independent. A resolved `BoardPresentation`
contains:

- square, selection, legal-move, and last-move colors;
- piece and promotion assets;
- board and piece geometry;
- animation rules and portable motion curves;
- ordered board zoom presets.

The provider supports text glyphs and self-contained tintable SVG. Rust bounds
and validates SVG input before it crosses the ABI, rejecting active content,
entities, external references, and CSS URLs. The CC0 Silhouette SVG files and
their provenance are embedded under
`crates/libchess-board/assets/cc0-silhouette`.

### `libchess-lichess`

`libchess-lichess` is the online platform adapter. Its descriptor advertises
only the features implemented by this build:

- account lookup;
- OAuth 2 authorization-code flow with PKCE;
- Lichess computer games;
- live-game catalog and per-game streams;
- moves and game actions;
- recent game history;
- PGN export;
- provider-supplied game review data;
- real-time catalog events.

Challenges and matchmaking exist as common capability identifiers but are not
advertised by this adapter.

Provider requests use authenticated HTTP. Long-lived Board API game and account
event feeds use newline-delimited JSON over streaming HTTP. The implementation
does not use the private WebSocket protocol used by the Lichess website.

The descriptor also owns the Lichess display metadata, web origin, OAuth client
identifier, callback URI, authorization origin, and default computer-game
selections. The macOS target does not reproduce those provider values.

### `libchess-stockfish`

`libchess-stockfish` is a local backend backed by an actual UCI subprocess. It
checks `LIBCHESS_STOCKFISH`, `PATH`, and conventional installation paths, starts
the candidate, completes a bounded `uci`/`isready` handshake, and presents the
reported engine name in the backend catalog. Stockfish absence or probe failure
is represented as backend availability data rather than an application startup
failure.

The descriptor supplies all 21 Stockfish skill levels, Standard and From
Position variants, White/Random/Black choices, Unlimited time, and their
defaults. Each local game owns a persistent engine process configured with one
thread, a 16 MiB hash, disabled pondering, and the selected skill. Blocking
process I/O and searches run outside the async runtime. Engine moves are checked
against `libchess-rules` legal moves before they become authoritative state.

Local sessions use the same live-game catalog, stream, prediction, action,
history, export, and review contracts as Lichess. History is currently in-memory.
PGN is generated from rules-derived SAN, and post-game review launches a bounded
full-skill Stockfish analysis for each position. Local engine errors roll a
tentative player move back transactionally before an authoritative update is
published.

### `libchess`

`libchess` is the composition layer. `ClientBuilder` owns backend factories and
board providers, selects one backend, creates it through either its local or
authenticated connection method, owns the pending OAuth session, and registers
validated user board and piece definitions.

The default client installs Lichess, Stockfish, and the built-in board provider.
Adding a future platform or local engine requires a new
`PlatformBackendFactory`; adding a future board catalog requires a
`BoardProvider`. Neither requires changing the C ABI merely to register another
implementation of the existing contracts.

### `libchess-ffi`

`libchess-ffi` is the only Rust crate that permits the unsafe operations needed
for the C boundary. It exports:

- `libchess_api_version`;
- `libchess_client_create`;
- `libchess_client_send`;
- `libchess_client_destroy`.

Each client handle owns one `libchess-worker` thread, one current-thread Tokio
runtime, an unbounded command channel, live-stream tasks keyed by game ID, one
catalog stream task, authoritative snapshots for active games, and retained
game reviews.

Commands and events are UTF-8 JSON envelopes with API `version: 1`, an optional
`request_id`, and a flattened `type` payload. The native wrapper checks the C API
version before creating a client. Request identifiers correlate asynchronous
results and errors with the initiating UI operation.

`ready` contains the backend catalog and current selection. The generic
`select_backend` command chooses a descriptor by ID; local selection immediately
creates an account and connection, while an OAuth selection waits for
`begin_oauth`. `backend_selection_changed` keeps each native frontend
synchronized, and `clear_backend_selection` returns the app to the launcher.
Starting OAuth with no frontend-supplied configuration uses the selected
descriptor's trusted Rust configuration; optional legacy fields remain
decodable for ABI compatibility.

The event callback receives borrowed bytes on the Rust worker thread. Both
native wrappers copy those bytes immediately and dispatch decoding onto their
UI thread. Rust zeroizes serialized event buffers after the callback returns.
Destroying the handle requests shutdown, stops live tasks, and joins the worker
thread.

The current command queue is unbounded. A bounded queue or explicit producer
backpressure policy has not been implemented.

## macOS frontend

The macOS product requires macOS 14 or newer and is split into three Swift
targets:

- `CLibChess` exposes the C header and links `liblibchess_ffi.dylib`;
- `LibChessKit` owns the native wrapper, decoded models, application store,
  persistence adapters, and portable-to-native presentation mapping;
- `LibChessMac` owns AppKit lifecycle and SwiftUI presentation.

### Application and window lifecycle

The executable uses an explicit `NSApplication` and `NSApplicationDelegate`
rather than a SwiftUI `WindowGroup`. AppKit owns the application menu, URL-open
callback, reopen behavior, and window lifetimes. SwiftUI content is hosted in
`NSHostingView` instances.

The app currently owns:

- one reusable, fixed-size floating `NSPanel` containing backend selection and
  authentication;
- one reusable main `NSWindow`, created lazily after a selected backend reports
  a matching connected account, containing the sidebar and game workspace;
- one reusable settings `NSWindow` for board and piece customization;
- an account popover opened from the account control;
- one reusable floating-board `NSPanel`.

`LibChessStore` is a single `@MainActor` observable store shared by the main,
settings, and floating-board surfaces. It holds provider state, the account,
live-game summaries and detailed snapshots, focused-game selection, pending
requests, history, exports, reviews, chat, board presentation, and transient
predictions.

### Backend launcher

Before a backend is connected, the app shows a compact 760-by-470-point welcome
panel modeled on Xcode's launcher window. It has a branded action pane on the
left, broad backend action rows supplied by the Rust catalog, and a quiet
context pane on the right. The panel has only a close control, cannot be
resized, floats while LibChess is active, and hides while another application
such as the system browser is active.

Selecting an available local engine connects it and transitions directly to the
workspace. Selecting an OAuth service keeps the launcher visible and renders
sign-in, saved-account, browser-authorization, cancellation, and connection
progress in its context pane. The full resizable workspace window does not exist
until the backend publishes both a connected state and a matching account. A
disconnect or “Choose Another Backend” hides the workspace and returns to the
launcher.

The launcher does not switch over provider IDs. Backend-specific nouns,
connection configuration, option catalogs, and default values arrive through
the Rust descriptor. Swift retains only platform UI decisions such as list
grouping, layout, and SF Symbol rendering.

### Floating board

The floating board is a borderless, resizable, non-activating panel at floating
window level. Its visible content is only the chessboard. It follows the current
board theme and the player's perspective and shares the same live state and move
submission path as the main window.

The panel:

- remains available across Spaces and as a full-screen auxiliary window;
- preserves a square aspect ratio between 240 and 960 points;
- restores its previous frame;
- provides an 18-to-24-point resize hit region around its edges;
- can be dragged by holding an empty square;
- uses direct AppKit frame updates while dragging or resizing;
- closes automatically when its game stops being playable.

A right-click context menu exposes draw and takeback offers or responses, claim
actions, reconnect, resign or abort confirmation, opening the full game, an
external provider page when the backend supplies one, and closing the floating
board. Those controls are deliberately absent from the normal board surface.

## Windows frontend

The Windows product is an unpackaged native WinUI 3 desktop application written
in C++20 with C++/WinRT. It targets Windows 10 build 19041 or newer and does not
host the CLR, a browser control, or a cross-platform UI abstraction. The Windows
App SDK runtime is currently copied beside the executable for a self-contained
developer build.

`NativeClient` loads `libchess_ffi.dll`, verifies C ABI version 1, copies every
borrowed callback payload on the Rust worker thread, and posts it through a
WinUI `DispatcherQueue`. Windows Runtime JSON APIs decode provider-neutral wire
models on the UI thread. The window and every launcher, navigation, form, status,
and board control are WinUI objects.

The Windows frontend implements the same current provider-neutral product areas
as the macOS frontend while following WinUI navigation, command, flyout, and
window conventions:

- the launcher renders backend discovery, selection, availability, explicit
  online sign-in, saved-account continuation, browser authorization controls,
  local-backend startup, and backend-supplied copy;
- Lichess OAuth PKCE uses the system browser, per-user protocol activation,
  callback redirection to the original process, and Windows Credential Manager;
- the connected `NavigationView` exposes new-game creation, a hierarchical
  ongoing-game list, history, appearance, and a footer account flyout with
  refresh, disconnect, saved-credential removal, and backend switching;
- live play includes native SVG and text pieces, Rust-provided palettes and
  motion, rounded and annotated boards, clocks, promotion, pockets and drops,
  prediction and rollback, offers and claims, reconnect, and termination;
- finished-game history opens an in-app review board with chess notation,
  opening data, evaluations, principal variations, service handoff, and native
  annotated-PGN export;
- the appearance surface selects and persists installed board, piece, and zoom
  choices and creates portable derived board themes or six-role SVG piece sets;
- a titleless, square, always-on-top utility window renders only the current
  board, resizes continuously, restores its frame, and exposes contextual game
  actions through a native menu; and
- Stockfish discovery covers `PATH`, WinGet, Chocolatey, and conventional
  installation directories.

The two frontends intentionally do not share widget layouts. They share Rust
contracts and product capabilities while presenting them through their native
platform conventions. Production Windows packaging remains follow-up work.

## Authentication and credentials

The OAuth flow is divided across the selected backend and native frontend:

```text
native launcher selects an opaque descriptor ID
        |
        v
Rust publishes selected descriptor -> launcher context pane
        |
        v
launcher begins OAuth
        |
        v
begin_oauth command using the platform callback identity
        |
        v
Lichess adapter creates state, verifier, and S256 challenge
        |
        v
oauth_authorization_required event
        |
        v
system browser -> native protocol callback
        |
        v
complete_oauth command
        |
        v
adapter validates callback and exchanges one-time code
        |
        +-- oauth_credential_issued -> native credential store
        +-- account_updated
        `-- connected state -> hide launcher and create/show workspace
```

The Lichess adapter fixes the scope to `board:play`, requires S256 PKCE, and
expires a pending authorization after ten minutes. macOS uses the client ID and
redirect URI in the Rust descriptor. Windows supplies its platform callback
identity when beginning the same Rust-owned transaction and validates the
authorization URL against the descriptor's trusted HTTPS origin before opening
it. The verifier remains inside Rust and never enters a command or event. The
access token crosses the ABI once so the native wrapper can persist it.

macOS stores each backend token as a generic-password Keychain item keyed by the
selected backend ID. It prefers the data
protection Keychain with `AfterFirstUnlockThisDeviceOnly` accessibility and
falls back to the file-based Keychain when the unsigned local build lacks the
required entitlement. Reads use a noninteractive `LAContext`; an inaccessible
item returns an error instead of displaying a password prompt. Keychain work is
performed away from the main actor.

The unpackaged Windows app registers `org.libchess.windows` per user through
Windows App Lifecycle. It is single-instanced: protocol activations from the
browser are redirected to the process that owns the pending OAuth session.
Callbacks must match the registered scheme, host, and path before they reach
Rust, which then performs the authoritative state and redirect validation.
Tokens are generic credentials keyed by backend ID in the current user's
Windows Credential Manager and persist only on the local machine.

Authenticated adapters hold credentials only in memory. Local connections do
not read or write platform credential storage. `AccessToken` redacts debug
output and zeroizes owned secret data on drop.

## Game creation and discovery

The creation flow is the common backend `create_bot_game` contract. Each
descriptor supplies opaque opponent identifiers, supported variants, player
colors, time-control choices, custom-position and move-history rules, and
explicit defaults.
Each native frontend renders that descriptor and returns selected values without
calculating a default, translating provider identifiers, or classifying a time
control.

The Lichess adapter validates the request against its descriptor, maps it to the
provider form, and returns a normalized game. These games are casual because the
Lichess AI endpoint does not offer a rated mode.

The Stockfish adapter validates the same request shape, creates a local session,
and starts its UCI process. When the player chooses Black, the engine makes the
first authoritative move before creation completes. Its normalized game result
does not contain a web URL, and the frontend consequently omits external-provider
actions without special-casing Stockfish.

Bot descriptors may also advertise a bounded reply-delay range, step, and
default. Stockfish advertises 0–2,000 milliseconds in 100-millisecond steps with
a 500-millisecond default; Lichess does not advertise this option. The native
creator renders the option only when present and sends the selected value through
the common `create_bot_game` request, without identifying the provider.

Variants independently advertise whether a custom X-FEN may retain preloaded
move history. The X-FEN is the root position and the optional move list contains
bounded UCI move identifiers replayed after that root. Rust validates every move
against the preceding reconstructed position. Stockfish advertises this support,
stores the reconstructed list in the normalized live board, and therefore lets
the regular move list, export, review, prediction, and takeback paths operate on
the loaded plies. Lichess does not advertise or accept this option because its AI
challenge endpoint accepts a position but cannot preserve a client-supplied
pre-game history. Turning the native "Load move history" option off sends only
the X-FEN and retains the previous position-only behavior.

After connection, the app loads the backend's ongoing-game catalog. Games are
identified and labeled using normalized provider summaries rather than a single
"current game" slot. A long-lived account event stream signals catalog changes;
the frontend refreshes the catalog and can maintain independent per-game stream
tasks for multiple active games.

## Live-game state and latency model

For each opened online game, the Lichess adapter consumes the authenticated
NDJSON game stream. It validates bounded lines and converts `gameFull`,
`gameState`, and chat events into normalized snapshots. Each local game exposes
the same stream contract through a Tokio watch channel. `libchess-rules`
reconstructs every board from the initial FEN and authoritative move list.

The native store keeps the last valid snapshot when a stream is interrupted,
projects clocks locally from the snapshot timestamp, reports stream state, and
can reconnect a game without discarding the board. The account event stream has
its own reconnect path and triggers catalog refreshes.

Moves use local prediction before waiting for the provider response:

```text
user selects a legal move
        |
        v
play_move command with request_id
        |
        v
FFI worker validates against its latest authoritative snapshot
        |
        v
libchess-rules reconstructs snapshot + proposed move
        |
        +-- move_predicted event -> native frontend displays predicted board
        |
        v
selected backend move submission
        |
        +-- request/engine error -> native frontend removes prediction and rolls back
        `-- success -> prediction remains until authoritative state advances
                                |
                                v
                     authoritative snapshot replaces prediction
```

For Stockfish, the blocking UCI search runs off the Tokio executor. The local
backend validates the predicted player move, asks the persistent engine for its
reply, validates that reply, and waits only for the remainder of the configured
minimum reply time before publishing the authoritative one- or two-ply state.
Engine thinking therefore occurs inside the default 500-millisecond response
window instead of being added after it. Initial engine moves for Black games are
not artificially delayed. This keeps selection and movement immediate while
preserving rollback on engine or rules errors.

Only one pending move is allowed per game, while different games may progress
independently. A prediction never changes the authoritative Rust snapshot. Game
actions such as draw, takeback, resign, abort, and claims continue to wait for
provider completion rather than predicting a terminal state.

Board orientation is derived from the normalized player color. Black games use
the reversed rank and file perspective in both the main and floating boards.

## History, export, and review

Finished-game history is paginated using a bounded page size and an opaque time
cursor. The Lichess adapter consumes the newest-first NDJSON user-game stream;
the Stockfish adapter serves newest-first entries from its in-memory local
catalog. Both emit the same normalized entries. Selecting any history entry
opens the native review workspace.

PGN export is requested through the provider adapter. Rust validates and bounds
the response and supplies a safe filename. The native frontend validates the
game identity, provider, filename, NUL absence, and an eight-megabyte size limit
before presenting the platform save picker.

Game review is backend-backed. Lichess returns the initial position, SAN,
normalized move identifiers, clocks, opening data, and any evaluations, best
lines, and judgments present in provider data; missing evaluation data remains
missing. Stockfish generates SAN and position evaluations locally after the
game. The FFI worker retains a loaded review and reconstructs requested plies
through `libchess-rules`; each native frontend renders either source without
opening a browser or parsing PGN itself.

## Board customization and persistence

User board and piece definitions use the same portable models as built-in
themes. A custom board derives from an installed board, may override palette
entries, and may apply bounded hue, saturation, and brightness adjustments. A
custom piece theme derives from an installed piece set, may override colors, and
may provide six validated tintable SVG roles.

Rust validates the complete customization state and rejects unknown bases,
built-in identifier shadowing, duplicate definitions, missing roles, unsafe or
oversized assets, and oversized catalogs. Successful mutations return the full
validated state and updated provider catalog.

The native settings surfaces edit these portable values, but they do not perform
theme composition or color math. The validated state is encoded as JSON and
written to the platform application-data location:

```text
~/Library/Application Support/LibChess/board-customization.json
%LOCALAPPDATA%\LibChess\board-customization.json
```

macOS performs the work away from the main actor and stores selections in
`UserDefaults`. Windows stores selections under
`HKCU\Software\LibChess\Windows`. Each frontend maps portable motion rules to
native animations and honors the operating system's animation accessibility
setting.

## Storage ownership

| Data | Owner | Lifetime |
| --- | --- | --- |
| OAuth access token | macOS Keychain or Windows Credential Manager | Persistent and device-local where supported |
| Custom board and piece definitions | macOS Application Support or Windows Local AppData JSON | Persistent |
| Selected themes and zoom | `UserDefaults` or `HKCU\Software\LibChess\Windows` | Persistent |
| Floating panel/window frame | AppKit frame autosave or the Windows preference key | Persistent |
| OAuth verifier and state | Authenticated adapter | In memory; Lichess expires it after ten minutes |
| Selected backend, active backend, and access-token copies | Rust client | In memory until cleared, disconnected, or destroyed |
| Local Stockfish game catalog and UCI processes | Stockfish backend | In memory for the selected backend's lifetime |
| Live games, predictions, history, exports, and reviews | Rust worker and `LibChessStore` | In memory for the process or backend selection |

## Validation and trust boundaries

Provider data is treated as untrusted at every layer:

- Rust validates identifiers, lengths, enum-like wire values, URLs, NDJSON line
  sizes, response structure, legal moves, PGN, review data, and SVG assets.
- Online backend descriptors carry a trusted HTTPS web origin. Each native
  frontend verifies returned game and analysis URLs against it before opening
  them; local games have no URL and expose no external-page action.
- OAuth authorization URLs are checked against the selected descriptor's
  authorization origin, and callbacks against its redirect URI.
- Each native frontend correlates asynchronous results with pending request
  identifiers and revalidates decoded collections, board states, filenames,
  URLs, and payload sizes.
- No arbitrary engine command or executable path crosses the ABI. The Stockfish
  adapter owns discovery and UCI text, and the shared core guard rejects engine
  use in every live online context.
- Rust implementation types and pointers never become frontend application
  models; only the C handle and copied JSON bytes cross the ABI.

## Build and verification

`scripts/check.sh` is the source-verification workflow. It runs Rust formatting,
workspace tests, Clippy with warnings denied, the release FFI build, and Swift
builds and tests.

`scripts/build-macos-app.sh` is the complete local packaging workflow. It:

1. validates macOS, Cargo, Xcode, Swift, the macOS SDK, manifests, and
   `Info.plist`;
2. creates its build root and every Swift cache, configuration, security, module,
   and product directory;
3. builds `libchess-ffi` and `LibChessMac` in release mode;
4. validates both Mach-O artifacts;
5. assembles a clean staging `LibChess.app` with the Rust dylib under
   `Contents/Frameworks`;
6. removes the source-checkout rpath and verifies the embedded Frameworks rpath;
7. ad-hoc signs and strictly verifies the app;
8. transactionally replaces the previous generated app and cleans staging.

The default output is:

```text
.build/LibChess.app
```

`LIBCHESS_BUILD_DIR` may select another dedicated build root. The release Cargo
profile favors a small binary through size optimization, fat LTO, one codegen
unit, symbol stripping, and abort-on-panic behavior.

`scripts/build-windows-app.ps1` is the native Windows build workflow. It restores
the pinned packages, builds `libchess-ffi.dll`, builds the C++/WinRT WinUI 3
executable with MSBuild, and copies the DLL beside the unpackaged executable.
`-Configuration Debug` selects a debug build and `-Run` starts the result.

## Current extension boundaries

The intended portable seams exist, but the following work is required before
the broader product matches the long-term design:

- A Chess.com integration needs a new platform factory and backend using an
  officially authorized API. No Chess.com networking code exists today.
- Windows still needs production packaging. Linux needs its native wrapper and
  renderer.
- Local history needs durable persistence if games must survive backend changes
  or application restarts.
- Interactive free-form engine analysis needs new commands beyond the current
  finished-game review contract.
- Human challenges and matchmaking need new shared request/result contracts and
  provider implementations.
- Production macOS distribution needs entitlements, Developer ID signing,
  notarization, and packaging beyond the current local ad-hoc build.
