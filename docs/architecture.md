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
       /    \
platform    engine
provider    provider
   |           |
Lichess     Stockfish
Chess.com   future engines
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

Provider descriptors also carry their trusted web origin. The current slice
uses it to validate the returned game URL before a native frontend opens it,
without hard-coding `lichess.org` into the shared UI.

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
bot_game_created event ---> native board (future)
                       `--> provider game URL (current slice)
```

Human challenges, matchmaking, and local engine games are intentionally
outside this first creation contract. Lichess AI games are intrinsically
casual; there is no rated option on that provider endpoint.

## Live-play safety invariant

Engine analysis is rejected whenever the active context is a live online game,
rated or casual. This rule is enforced in `libchess-core`, below every native
frontend, so a UI bug cannot accidentally enable assistance. Post-game review,
offline analysis, and local computer games are separate contexts.

## Credentials

Provider adapters receive credentials in memory but never persist or log them.
Each native wrapper owns secure persistence using its platform facility. The
macOS wrapper uses Keychain. OAuth is split cleanly:

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

Lichess NDJSON streams, clock projection, reconnection, and move submission all
remain inside the Lichess adapter and application service. The frontend receives
normalized game snapshots rather than raw Lichess payloads.
