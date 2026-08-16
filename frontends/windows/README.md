# LibChess for Windows

This frontend is a native, unpackaged WinUI 3 desktop application written in
C++/WinRT. It does not use WebView, Electron, React Native, .NET, or another UI
abstraction. The process hosts Windows App SDK XAML controls and talks directly
to `libchess_ffi.dll` through the repository's versioned C ABI.

## Prerequisites

- Windows 10 version 2004 (build 19041) or newer
- Visual Studio 2022 with **Desktop development with C++**
- Rust with the MSVC host toolchain
- PowerShell 7 or Windows PowerShell 5.1

The Windows App SDK, C++/WinRT, and SDK build tools are pinned in
`packages.config` and restored into the ignored local `packages` directory.
The app is self-contained with respect to the Windows App SDK runtime.

## Build

From the repository root:

```powershell
.\scripts\build-windows-app.ps1
```

Use `-Configuration Debug` for a debug build or `-Run` to start the produced
app after a successful build.

The Windows slice implements backend discovery and selection, Lichess OAuth
with PKCE in the system browser, per-user protocol activation, secure token
persistence in Windows Credential Manager, saved-account reconnection, local
backend connection, backend-advertised game defaults, and ongoing-game
navigation. The live workspace includes a backend-presented board with native
SVG support, themes and zoom, rounded chrome, coordinates, layered move/check
indicators, piece motion, promotions, variant pockets and drops. It also
includes ticking clock/correspondence/unlimited displays, move history,
draw/takeback offers, disconnect claims, abort/resign confirmation, stream
reconnection, and provider browser handoff.

The connected workspace also provides a paged game-history list and a native
review surface with Rust-reconstructed positions, opening data, move stepping,
stored evaluations, judgment details, principal variations, and service
analysis handoff. Backend-generated annotated PGN can be exported through the
native Windows file picker.

The Appearance page applies Rust-provided board and piece themes globally,
persists the selection, and creates or edits portable derived themes. Custom
piece themes can inherit installed assets or import the six validated SVG
roles. Theme-library state is saved under `%LOCALAPPDATA%\LibChess` and restored
through the versioned FFI. A playable live board can also be detached into a
titleless, square, always-on-top WinUI utility panel with native edge resizing.
It stays out of normal window switching and exposes game actions through its
context menu.

Packaging remains follow-up work.

The unpackaged developer build registers `org.libchess.windows` for the current
user when the app starts. Windows App Lifecycle redirects the browser callback
to the already-running process, preserving the pending PKCE verifier that is
owned by Rust. A production installer should unregister the protocol during
uninstall.

Bounded diagnostic logs are written to
`%LOCALAPPDATA%\LibChess\Logs\libchess.log`. OAuth entries record the command
and event sequence plus sanitized URI scheme/host/path metadata. Authorization
URLs, callback query values, authorization codes, PKCE state and verifier
values, and access tokens are never written to the log.
