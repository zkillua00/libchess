# Architecture

## Boundary

```text
SwiftUI / WinUI 3 / Qt
          |
    native wrapper
          |
 versioned C ABI (commands in, events out)
          |
                    libchess
              /        |        \
      platform       engine      board
      provider       provider   provider
         |              |          |
      Lichess        Stockfish   assets, palette,
      Chess.com      future      metrics, motion,
                     engines     zoom presets
```

The frontend renders state and performs operating-system integration. It does
not know Lichess endpoints, response shapes, chess-server rate limits, or game
rules. `libchess` does not know SwiftUI, WinUI, Qt, Keychain, Credential
Manager, or Secret Service.

The FFI uses a C ABI because it is the stable common denominator for Swift,
.NET P/Invoke, and Qt/C++. Rust implementation types never cross that boundary.
Commands and events use a versioned JSON envelope so adding fields does not
break already-built frontends. The only `unsafe` Rust belongs in the tiny FFI
crate.

## Providers are capability based

Lichess and Chess.com are platform providers. Stockfish is an engine provider,
not a substitute chess server. They intentionally implement different ports:

- A platform provider supplies identity, matchmaking, challenges, online game
  streams, moves, and platform-specific exports when available.
- An engine provider supplies offline opponents or position analysis.

The provider descriptor advertises capabilities implemented by the current
adapter build. A frontend can therefore hide unsupported actions without
branching on `provider == lichess`; it never advertises merely theoretical
platform capabilities. Capability names are forward-compatible wire values:
native wrappers retain unknown names so adding a backend capability does not
prevent an older frontend from starting.

New platform adapters register a factory with `ClientBuilder`; existing native
frontends continue to use the same command/event protocol.

## Board customization is portable

Board appearance is a separate provider axis; it does not belong to a chess
platform adapter or a native frontend. A board provider advertises independent
board-theme and piece-theme catalogs. A selection combines one of each into a
validated presentation containing square colors and geometry, piece and
promotion assets for each player color, piece styling, animation curves and
durations, transition behavior, and ordered zoom presets. The registry is owned
by `libchess`, so installing another board provider does not change Lichess, a
future Chess.com adapter, or an engine provider.

The C ABI exposes the board-provider catalog and the selected presentation in
the same versioned event stream as application state. Native wrappers decode
that portable description and translate semantic values into their native
rendering APIs—for example, SwiftUI `Color`, `Animation`, and transitions.
They may own OS integration such as preference persistence and Reduce Motion,
but they do not define a fallback piece set, palette, animation timing, or zoom
catalog. WinUI 3 and Qt can therefore render exactly the same installed board
themes without recreating customization policy. Motion curves are portable
semantics such as `spring` and `ease_out`; each renderer maps those semantics to
its closest native animation primitive.

The built-in `libchess-board` provider supplies Classic, Slate, Walnut, Ocean,
Charcoal, and Rosewood boards. Piece selection is independent: System Solid,
System Outline, CC0 Silhouette, and Notation can be paired with any board. The
tagged asset contract supports tintable text glyphs and self-contained SVG.
Rust bounds and validates SVG payloads and rejects scripts, entities, external
references, and CSS URLs before they cross the ABI; native renderers cache the
decoded result.

The CC0 Silhouette vectors are embedded at compile time from femrek's
[CC0 OpenGameArt release](https://opengameart.org/content/chess-pieces-in-svg-format).
The original bytes, retrieval date, license link, and SHA-256 checksums live
beside the assets under `crates/libchess-board/assets/cc0-silhouette`.

## History, exports, and post-game analysis

Finished-game history is a provider capability, not a frontend-specific API.
The shared request carries the authenticated account identity, a bounded page
size, and an opaque time cursor. A provider returns normalized opponent,
variant, result, timestamp, game URL, and analysis URL fields plus the next
cursor. Frontends can therefore render and paginate a native game library
without knowing a provider route or response schema.

PGN export is a separate capability. The provider adapter fetches and bounds
the payload, validates that it is textual PGN, and returns a safe suggested
filename. The native wrapper validates the provider origin and export size
again before opening the operating system save panel. For Lichess, recent
games use the newest-first NDJSON user-game stream, and export requests ask for
clocks, opening metadata, existing evaluations, and literate annotations.

Game review is another separate capability. A provider returns a normalized
initial position, SAN display text, provider-neutral move identifiers, clock
values, opening metadata, evaluations, best lines, and move judgments. The FFI
worker retains the review and uses `libchess-rules` to reconstruct any requested
ply. Frontends therefore render a native replay and analysis workspace without
parsing PGN, provider JSON, or provider URLs. Missing provider evaluations are
represented as missing data rather than invented analysis. A future engine
adapter can fill those positions in the same post-game context without changing
the native review surface.

## Game creation

Bot games are the first creation flow. A provider that advertises the
`bot_games` capability also advertises opaque bot identifiers and a complete
bot-game option descriptor. The descriptor contains variants, player colors,
the exact accepted clock values and any speed floor, correspondence intervals, unlimited-play
support, and per-variant custom-position support. Frontends render these values
and return their identifiers unchanged; only the provider adapter interprets
them. Lichess currently maps `level-1` through `level-8` to AI levels and maps
the common kebab-case variant identifiers to Lichess's API keys. A future
Chess.com adapter can advertise named personalities and its own supported
settings without changing the common models or native frontends.

Provider descriptors also carry their trusted web origin. The native wrapper
validates every returned game URL against that origin before presenting an
optional provider-site link, without hard-coding `lichess.org` into the shared
UI.

The shared request contains only normalized game choices: opponent and variant
identifiers, one tagged time control (`clock`, `correspondence`, or
`unlimited`), requested player color, and an optional initial FEN. The Lichess
adapter checks every value against its advertised descriptor, enforces custom
position compatibility, and rejects clocks faster than Blitz for Board API
compliance. It then maps the request to the provider-specific form, omitting
mutually exclusive fields, and validates the returned game identifier,
variant, color, and casual rating mode before emitting a normalized result:

```text
create_bot_game command
        |
        v
active PlatformBackend
        |
        v
provider bot-game endpoint
        |
        v
bot_game_created event
        |
        v
start_live_game command
        |
        +--> live_game_updated events ---> native board
        `--> play_move / perform_game_action commands
```

Human challenges, matchmaking, and local engine games are intentionally
outside this first creation contract. Lichess AI games are intrinsically
casual; there is no rated option on that provider endpoint.

## Live-play safety invariant

Engine analysis is rejected whenever the active context is a live online game,
rated or casual. This rule is enforced in `libchess-core`, below every native
frontend, so a UI bug cannot accidentally enable assistance. Post-game review,
offline analysis, and local computer games are separate contexts.

## Rules and live-game state

`libchess-rules` reconstructs a position from its initial FEN plus the
authoritative move list. It uses the same normalized output for Standard,
Chess960, Crazyhouse, Antichess, Atomic, Horde, King of the Hill, Racing Kings,
and Three-check. Each snapshot contains pieces, pockets, side to move, check
state, move history, the last move, and provider-ready legal move identifiers.
Castling keeps a human board destination while retaining the provider's UCI
identifier; Crazyhouse drops have no source square.

The frontend can therefore render and submit only moves advertised in the
snapshot. It does not embed a second chess rules implementation, and a future
Chess.com adapter can reuse the rules crate and the same live-game contract.

## Credentials

Provider adapters receive credentials in memory but never persist or log them.
Each native wrapper owns secure persistence using its platform facility. The
macOS wrapper uses Keychain. It prefers the data-protection Keychain with an
after-first-unlock, device-only accessibility class and migrates a readable
legacy item opportunistically. Every lookup supplies a noninteractive
`LAContext`, so a locked or obsolete item returns an error instead of presenting
authentication UI. Keychain work also runs away from the main actor.

OAuth is split cleanly:

1. The frontend asks `libchess` to begin OAuth for an advertised provider.
2. The provider adapter creates the state, verifier, S256 challenge, and
   authorization URL. It owns the pending session and fixes the scopes it
   supports; the frontend cannot broaden them.
3. The native frontend opens the system browser and receives the callback.
4. Rust checks the callback target, expiry, unique state, and authorization
   result before exchanging the one-time code.
5. The adapter validates the token response and account before returning the
   credential to the native wrapper for secure persistence.

For Lichess, the implemented scope is `board:play`, the pending authorization
expires after ten minutes, and code challenge method `S256` is mandatory. The
PKCE verifier never enters an FFI command or event. The access token crosses
the ABI once in a dedicated credential event because secure storage is an OS
responsibility; Rust redacts it from debug output and zeroizes owned copies on
drop.

The corresponding frontend-neutral exchange is:

```text
begin_oauth command
        |
        v
oauth_authorization_required event ---> native system browser
                                                |
                                                v
complete_oauth command <---------------- callback URL
        |
        +-- oauth_credential_issued event ---> OS credential store
        +-- account_updated event
        `-- connected state
```

Windows and Linux will supply their own client identifier, callback URI,
browser launcher, and credential store while reusing this exact backend
protocol. A future Chess.com adapter can own a different OAuth endpoint and
scope policy behind the same provider factory.

## Concurrency and streaming

The C ABI owns one Rust worker thread and one asynchronous runtime per client
handle. Native code sends commands without blocking its UI thread. Rust emits
immutable event snapshots through a callback; each wrapper copies the bytes and
marshals decoding onto its UI executor.

Lichess exposes the Board API game feed as authenticated streaming HTTP with
NDJSON rather than WebSockets. The adapter owns that wire protocol, validates
bounded event lines, reconstructs every authoritative position, and maps
move/game-action commands to the Board API. The frontend receives normalized
game snapshots rather than raw Lichess payloads. It projects clocks between
snapshots and can restart an interrupted stream without discarding the last
valid board.
