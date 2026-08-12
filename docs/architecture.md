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
platform capabilities.

New platform adapters register a factory with `ClientBuilder`; existing native
frontends continue to use the same command/event protocol.

## Live-play safety invariant

Engine analysis is rejected whenever the active context is a live online game,
rated or casual. This rule is enforced in `libchess-core`, below every native
frontend, so a UI bug cannot accidentally enable assistance. Post-game review,
offline analysis, and local computer games are separate contexts.

## Credentials

Provider adapters receive credentials in memory but never persist or log them.
Each native wrapper owns secure persistence using its platform facility. The
macOS wrapper uses Keychain. The planned OAuth flow is split cleanly:

1. Rust creates the PKCE authorization request.
2. The native frontend opens the system browser and receives the callback.
3. Rust validates the callback and exchanges the code.
4. The native wrapper stores the resulting opaque token securely.

## Concurrency and streaming

The C ABI owns one Rust worker thread and one asynchronous runtime per client
handle. Native code sends commands without blocking its UI thread. Rust emits
immutable event snapshots through a callback; each wrapper copies the bytes and
marshals decoding onto its UI executor.

Lichess NDJSON streams, clock projection, reconnection, and move submission all
remain inside the Lichess adapter and application service. The frontend receives
normalized game snapshots rather than raw Lichess payloads.
