# steamworks.d

D bindings for the [Steamworks SDK](https://partner.steamgames.com/doc/sdk) flat C API: every
interface, method, callback, struct, enum and constant of **Steamworks SDK 1.65**, generated from
the SDK and verified against its headers and libraries on every platform Valve ships, with a thin
D layer for initialization, callback dispatch and conversions on top.

- **Complete.** All 1057 functions the SDK headers declare and `libsteam_api` exports, all 34
  interfaces with their accessors and version strings, 196 callback structs, the plain structs,
  115 enums, 163 constants and 78 typedefs. Nothing is a demo subset.
- **Faithful.** Valve's C and C++ names throughout, so the
  [Steamworks API reference](https://partner.steamgames.com/doc/api) applies as written.
- **ABI-verified.** Sizes, alignments, field offsets, enumerator and constant values, function
  signatures, vtable layouts and symbol names are checked against the SDK headers (with clang) and
  libraries for macOS (arm64, x86_64), Windows (x64, x86), Linux (x86_64, i686, arm64) and
  Android (arm64), with dmd and ldc2. See [ABI verification](#abi-verification).
- **Two linking modes.** Load `libsteam_api` at run time (the default, so a game can run without
  it) or link it directly, with the same code.
- **Standalone.** No dependencies beyond druntime and Phobos; every raw function is
  `nothrow @nogc`.
- **A thin D layer**: initialization that reports Steam's error message, the `SteamUser()`-style
  accessors, a per-frame callback and call-result dispatcher (with a `nothrow @nogc` variant),
  delegate-based server browser responses, and Steam ID, network address and string conversions.

This project is not affiliated with or endorsed by Valve Corporation. See [License](#license).

## Contents

- [Installation](#installation)
- [Getting the Steamworks SDK](#getting-the-steamworks-sdk)
- [Quick start](#quick-start)
- [Raw API and D layer](#raw-api-and-d-layer)
- [Examples](#examples)
- [Platform notes](#platform-notes)
- [How the C API maps to D](#how-the-c-api-maps-to-d)
- [Modules](#modules)
- [Deliberately not bound](#deliberately-not-bound)
- [Development](#development)
- [License](#license)

## Installation

Add the package to `dub.sdl`:

```sdl
dependency "steamworks" version="~>0.1.0"
```

or `dub.json`:

```json
"dependencies": { "steamworks": "~>0.1.0" }
```

(Until the package is published on code.dlang.org, use a path or git dependency.) Compilers:
dmd and LDC, recent releases (CI uses the latest of each). The package has two configurations.

### `dynamic` (default)

Every flat function is a `__gshared` function pointer that `loadSteamworks()` binds at run time.
Nothing links against `libsteam_api`, so the package builds without the SDK, and a game can run,
and fall back gracefully, where the library is missing (such as a DRM-free build of the same
binary). This is the recommended mode.

```d
import steamworks;

if (loadSteamworks() != SteamworksLoadStatus.success)  // next to the executable, then the system search path
    writeln("no Steam: ", steamworksLoadError());       // or loadSteamworks("path/to/libsteam_api.so")
```

`loadSteamworks` returns `success`, `libraryNotFound`, or `missingSymbols` (an older library: the
functions it has are bound and the rest stay `null`; see `steamworksMissingSymbolCount`).
`unloadSteamworks()` releases the library after `SteamAPI_Shutdown()`. Calling a flat function
before `loadSteamworks()` succeeds dereferences a null pointer; the D layer's `steamInit` and
friends check for this and report an error instead, and the accessors (`SteamUser()`,
`SteamAPI_SteamUser()`, `SteamClient()`, ...) return null. Loading is not thread-safe: load once at
start-up, before other threads use Steam.

### `linked`

Functions are plain `extern (C)` declarations and the library is linked at build time. Select the
configuration and tell the linker where the library is:

```sdl
dependency "steamworks" version="~>0.1.0"
subConfiguration "steamworks" "linked"
lflags "-L/path/to/sdk/redistributable_bin/linux64" "-rpath=$$ORIGIN" platform="linux-x86_64"
lflags "-L/path/to/sdk/redistributable_bin/osx" platform="osx"
lflags "/LIBPATH:C:\\path\\to\\sdk\\redistributable_bin\\win64" platform="windows-x86_64"
```

The package links `steam_api` (`steam_api64.lib` on 64-bit Windows). In this mode
`loadSteamworks()` simply returns `success`, so code written for the dynamic mode works unchanged;
code that needs to tell the modes apart can test `version (SteamworksDynamic)`.

## Getting the Steamworks SDK

The SDK and its redistributable libraries are **not included** in this repository or package.
Download the SDK from the [Steamworks partner site](https://partner.steamgames.com/downloads/list)
(a Steamworks account is required) and ship the library for each platform next to your
executable:

| Platform      | File (from `sdk/redistributable_bin`) |
| ------------- | ------------------------------------- |
| Windows x64   | `win64/steam_api64.dll`               |
| Windows x86   | `steam_api.dll`                       |
| macOS         | `osx/libsteam_api.dylib` (universal)  |
| Linux x86_64  | `linux64/libsteam_api.so`             |
| Linux i686    | `linux32/libsteam_api.so`             |
| Linux arm64   | `linuxarm64/libsteam_api.so`          |
| Android arm64 | `androidarm64/libsteam_api.so`        |

The linked configuration also needs the import library `win64/steam_api64.lib` (or
`steam_api.lib`) on Windows at build time.

**Ship the library from SDK 1.65**, the version these bindings are generated from. The flat API
is tied to its SDK release: a different release's `libsteam_api` exports other versioned
accessors (the SDK 1.64 library exports `SteamAPI_SteamUtils_v010` where these bindings call
`_v011`, for example) and can change function signatures (1.65 added a parameter to
`SteamAPI_ISteamNetworkingSockets_SendMessages`). With the dynamic configuration a mismatched
library shows up as `SteamworksLoadStatus.missingSymbols`; with the linked configuration as
unresolved symbols. To move to another SDK release, [regenerate](#regenerating-for-a-new-sdk) the
bindings.

For working on this repository, `tools/fetch-sdk.sh` puts an SDK into `./sdk` (gitignored): it
copies the official SDK from `$STEAMWORKS_SDK` if set, and otherwise downloads the copy of the SDK
1.65 headers and redistributables in the [steamworks-rs](https://github.com/Noxime/steamworks-rs)
repository at a pinned commit, verified by the SHA-256 of `steam_api.json`, `steam_api_flat.h`,
every redistributable library and a digest of all extracted files (GitHub tarballs themselves are
not byte-stable). `STEAMWORKS_SDK_VERSION=1.64` fetches the previous release from the
`steamworks-sys` crate instead, for comparison. Use the official download for anything you ship.

## Quick start

During development, put a `steam_appid.txt` containing your app ID in the working directory (480,
Valve's Spacewar sample, works for testing). It lets `SteamAPI_Init` work when the game is not
launched from Steam; do not ship it. The Steam client must be running and logged in.

```d
import core.thread : Thread;
import core.time : msecs;
import std.stdio : writefln, writeln;
import steamworks;

void main()
{
    if (loadSteamworks() != SteamworksLoadStatus.success)
        return;                       // no library: run without Steam

    const init = steamInit();         // SteamAPI_InitEx, then manual dispatch
    if (!init)
    {
        writeln("Steam unavailable: ", init.message);
        return;
    }
    scope (exit) steamShutdown();

    const me = CSteamID(SteamAPI_ISteamUser_GetSteamID(SteamUser()));
    writefln("%s %s", fromCString(SteamAPI_ISteamFriends_GetPersonaName(SteamFriends())),
        me.toSteam3String);           // "[U:1:22202]"

    auto steam = CallbackDispatcher.forClient();

    // A callback: delivered every time Steam posts it, until unregistered.
    auto token = steam.register((ref const PersonaStateChange_t e) {
        writefln("%s changed", CSteamID(e.m_ulSteamID).toSteam3String);
    });

    // A call result: the result type comes from the function's attribute.
    steam.call!SteamAPI_ISteamUserStats_FindLeaderboard(SteamUserStats(), "Feet Traveled")
        .then((ref r, ioFailure) {    // r is a LeaderboardFindResult_t
            if (!ioFailure && r.m_bLeaderboardFound) { /* ... */ }
        });

    // Achievements and stats: Steam fetches the user's stats during
    // initialization (UserStatsReceived_t); StoreStats uploads changes.
    steam.register((ref const UserStatsStored_t e) { writeln("stored: ", e.m_eResult); });
    if (SteamAPI_ISteamUserStats_SetAchievement(SteamUserStats(), "ACH_WIN_ONE_GAME"))
        SteamAPI_ISteamUserStats_StoreStats(SteamUserStats());

    foreach (frame; 0 .. 600)
    {
        steam.runFrame();             // callbacks and call results are delivered here
        Thread.sleep(16.msecs);       // render a frame
    }
    steam.unregister(token);
}
```

### Initialization

`steamInit()` calls `SteamAPI_InitEx`, which checks that the user's Steam client supports every
interface version these bindings call, and returns a `SteamInitResult` holding the
`ESteamAPIInitResult` and Steam's message; it converts to `true` on success. `result.message`
slices the result's own buffer, so keep the result in a variable (`steamInit().message` does not
compile) and `idup` the text to keep it longer. `steamInitOrThrow()`
throws a `SteamInitException` instead. Game servers use `steamGameServerInit(ip, gamePort,
queryPort, serverMode, version)` and `steamGameServerShutdown()`. After a successful
initialization both select manual dispatch (`SteamAPI_ManualDispatch_Init`, which steam_api.h
requires after `SteamAPI_Init`); pass `SteamDispatchMode.automatic` to keep Steam's own
`SteamAPI_RunCallbacks` dispatch. `steamRestartAppIfNecessary(appID)` wraps
`SteamAPI_RestartAppIfNecessary`: call it first in `main` and exit when it returns true.

The accessors carry their C++ names: `SteamUser()`, `SteamFriends()`, `SteamMatchmaking()`,
`SteamNetworkingSockets()`, ..., and `SteamGameServer()`, `SteamGameServerNetworkingSockets()`,
... for game servers. Each returns the raw interface pointer to pass as `self`, or null before
initialization (and, with the "dynamic" configuration, when the library is not loaded or lacks
that accessor).

### Callbacks and call results

`CallbackDispatcher` pumps one Steam pipe: `forClient()` uses `SteamAPI_GetHSteamPipe()`,
`forGameServer()` uses `SteamGameServer_GetHSteamPipe()` (a process that is both needs one of
each). Call `runFrame()` once per frame.

- `register!T(handler)` or `register(handler)` (type inferred from a `(ref const T e)` parameter;
  the parameter needs a name) subscribes a delegate or function pointer to callback struct `T`;
  it returns a `CallbackToken` for `unregister`. `registerRaw` receives Steam's `CallbackMsg_t`
  for one id or for all.
- `callResult!T(call, handler)` waits for the `SteamAPICall_t` returned by an asynchronous
  function; the handler gets `(ref const T result, bool ioFailure)` once. `call!fn(args).then(...)`
  makes the call and takes `T` from the function's `SteamCallResult` attribute. `cancel` stops
  waiting; an invalid handle registers nothing.
- Handlers may register, unregister, cancel and `clear` (themselves included) while running.
  A handler may also reset, reassign or destroy the dispatcher (`steam = CallbackDispatcher.init;`
  on `SteamShutdown_t`): the remaining handlers are skipped, the callback is still freed, and
  queued callbacks wait for the next `runFrame`. `runFrame` never allocates from the GC; handlers
  live in `malloc` memory scanned by the GC.
- `CallbackDispatcher` accepts any handler: if one throws, the others for the same callback
  still run, the callback is freed, and the exception leaves `runFrame` unchanged (several
  distinct exceptions arrive together in a `CallbackHandlersException`; the dispatcher never
  touches an exception's `next`); queued callbacks wait for the next frame.
  `NogcCallbackDispatcher` accepts only `nothrow @nogc` handlers, which makes `runFrame`
  `nothrow @nogc`.
- With `@safe` handlers, registering, `runFrame` and the rest are `@safe`; registering a
  `@system` handler is `@system`.
- The dispatcher is single-threaded and not copyable; `call!fn(...).then` keeps a pointer to it,
  so keep it in one place (a local in the main loop, a field of a class).
- The dispatcher reads from a `CallbackSource` interface (`@safe` methods; implement them as
  `@trusted` where needed), Steam's manual dispatch by default; tests inject synthetic
  callbacks and call results through it.

### Other conveniences

- `steamworks.matchmaking`: `ServerListResponse`, `PingResponse`, `PlayersResponse`,
  `RulesResponse` and `ServerFriendsResponse` implement the C++ `ISteamMatchmaking*Response`
  interfaces with delegates, for `ISteamMatchmakingServers`. Keep the object referenced from D
  while Steam holds it; the delegates are `nothrow`.
- `steamworks.steamid`: `id.accountID`, `id.universe`, `id.accountType`, `id.accountInstance`,
  `toSteam3String` / `formatSteamID` (`"[U:1:22202]"`, `@nogc` into a buffer),
  `toSteam2String` (`"STEAM_1:0:11101"`) and `parseSteamID` (decimal, Steam3 or Steam2 text).
- `steamworks.networking`: `ipAddrToString`, `parseIPAddr`, `identityToString`,
  `parseIdentity` and buffer-based `formatIPAddr` / `formatIdentity`, using Steam's own
  formatting. They need an initialized Steam (they return empty text or false before); so do the
  raw `SteamAPI_SteamNetworkingIPAddr_ToString`/`ParseString` and `SteamNetworkingIdentity`
  equivalents, which crash without it.
- `steamworks.strings`: `fromCString` borrows a returned `const(char)*` or a `char[N]` field as a
  slice, `idupCString` copies it, and `tempCString` makes a NUL-terminated copy of a D string
  without the GC.

## Raw API and D layer

`steamworks.raw` is the complete flat API exactly as Valve declares it: anyone who knows the C API
(or reads Valve's documentation) can use it directly, and nothing in the D layer is needed to
reach any feature. The D layer (`steamworks.lifecycle`, `.accessors`, `.dispatch`,
`.matchmaking`, `.steamid`, `.networking`, `.strings`) only removes boilerplate: error messages
from initialization, the dispatch loop, delegate-based C++ callback objects, and text
conversions. `import steamworks;` imports both; import `steamworks.raw` alone for the bare API.
The two mix freely: the dispatcher hands handlers the raw callback structs, and the accessors
return the raw interface pointers.

## Examples

Each directory under `examples/` is a dub package (`dub build --root=examples/<name>`, or
`dub run` from inside it). They build without Steam and, when Steam is not running, report why
initialization failed and exit. Each copies the SDK's library next to its executable, so they
need the SDK in `./sdk` (`tools/fetch-sdk.sh`); run them with a `steam_appid.txt` in the working
directory.

| Example                                         | Shows                                                                                       |
| ----------------------------------------------- | ------------------------------------------------------------------------------------------- |
| [`dispatcher`](examples/dispatcher)             | Minimal program: initialization, a callback and two call results with the dispatcher.       |
| [`manual-dispatch`](examples/manual-dispatch)   | The same with the raw API only: `SteamAPI_ManualDispatch_*` and `GetAPICallResult`.          |
| [`achievements`](examples/achievements)         | Achievements, stats and global percentages; leaderboards through chained call results.     |
| [`matchmaking`](examples/matchmaking)           | Lobbies (create, search with filters, join, chat, member changes) and the server browser.  |
| [`networking`](examples/networking)             | `ISteamNetworkingSockets`: loopback socket pair, P2P listen socket and poll group, connect. |
| [`game-server`](examples/game-server)           | A dedicated server: game server init, anonymous logon, server browser rules, auth tickets. |

## Platform notes

- **Struct packing.** Steam's callback structs are packed to 4 bytes on Linux, macOS and Android
  (`VALVE_CALLBACK_PACK_SMALL`) and to 8 bytes on Windows (`VALVE_CALLBACK_PACK_LARGE`). The
  bindings reproduce both with `align(callbackAlign!T)` on every field, chosen by `version`, so
  the same source has the right layout everywhere; `steamworks.raw.platform` exposes
  `VALVE_CALLBACK_PACK`. Byte-packed structs use `align(1)`.
- **Windows.** Ship `steam_api64.dll` (or `steam_api.dll` for 32-bit) next to the executable;
  `loadSteamworks()` looks there first, then on the standard DLL search path. The linked
  configuration links the import library `steam_api64.lib`; add its directory with
  `lflags "/LIBPATH:..."` or `LINK=/LIBPATH:...` in the environment (dmd's `sc.ini` replaces
  `LIB`, so `LIB` works with LDC only). C++ callback interfaces follow MSVC's
  vtable order, which the D compilers reproduce for `extern (C++)` classes.
- **macOS.** `libsteam_api.dylib` is universal (arm64 and x86_64). Its install name is
  `@loader_path/libsteam_api.dylib`, so a linked executable finds it next to itself; inside an
  app bundle put it in `Contents/MacOS` next to the executable (or adjust with
  `install_name_tool`). For test binaries elsewhere, `DYLD_LIBRARY_PATH` pointing at the SDK's
  `osx` directory works. `loadSteamworks()` looks next to the executable, then on the dyld search
  path.
- **Linux.** The library is `libsteam_api.so` for each architecture. Ship it next to the
  executable and, for the linked configuration, link with an rpath of `$ORIGIN`
  (`lflags "-rpath=$$ORIGIN"` in dub) so it is found there; `LD_LIBRARY_PATH` works for
  development. `loadSteamworks()` looks next to the executable first, then on the loader's search
  path. The dynamic configuration links `libdl`.
- **Steam Deck / Proton.** The Windows build running under Proton uses the Windows DLL; the
  native Linux build uses `linux64`.
- **Game servers** need `steamclient` (`steamclient.so`, `steamclient.dll`), installed with the
  Steam client or SteamCMD, but no running Steam client.

## How the C API maps to D

- **Functions** keep their flat names: `SteamAPI_<Interface>_<Method>(self, ...)`. Interface
  pointers come from the accessors, e.g. `SteamUser()` (D layer) or `SteamAPI_SteamUser()` (the
  unversioned inline accessor of `steam_api_flat.h`, forwarding to the exported
  `SteamAPI_SteamUser_v023()`).
- **Header-inline functions** the library does not export are provided in D:
  `SteamAPI_Init`, `SteamAPI_InitEx`, `SteamGameServer_Init`, `SteamGameServer_InitEx`,
  `SteamGameServer_ReleaseCurrentThreadMemory`, `SteamClient`, `SteamGameServerClient`,
  `BIsHTTPStatusSuccess`, and the POP ID conversions `CalculateSteamNetworkingPOPIDFromString`
  and `GetSteamNetworkingLocationPOPStringFromID`, plus the trivial inline members of `CSteamID`, `CGameID`,
  `SteamIPAddress_t`, `SteamNetworkingIPAddr`, `SteamNetworkingIdentity` and
  `SteamNetworkingConfigValue_t`.
- **Steam IDs** cross the flat API as `uint64_steamid` (and `uint64_gameid`); `CSteamID` and
  `CGameID` are 8-byte, byte-aligned structs with the C++ accessors (`GetAccountID`,
  `GetEAccountType`, `IsValid`, ...), used in callback structs and in the virtual functions of the
  C++ callback interfaces (`ISteamMatchmakingServerFriendsResponse::AddFriendToList`).
- **Enums** are D enums with the C++ underlying type. Every enumerator is also available
  unqualified, as in C++: `k_EResultOK` and `EResult.k_EResultOK` are the same constant.
- **C++ references** (`const SteamNetworkingIPAddr &`) are `ref const(SteamNetworkingIPAddr)`;
  strings are `const(char)*`; fixed buffers such as `SteamErrMsg` are static arrays passed by
  pointer. A `char` passed by value (the gains of `TriggerSimpleHapticEvent`) is `c_char`,
  which is `byte` or `ubyte` as C's `char` is signed or unsigned on the target, because D's
  `char` is always unsigned.
- **Callback structs** carry `enum int k_iCallback` and the platform's packing (see
  [Platform notes](#platform-notes)).
- **Structs** default-initialize to all zero bytes, like C++ value-initialization (D would
  otherwise fill `char` arrays with `0xFF` and floats with NaN).
- **Asynchronous functions** carry their result type as a UDA:
  `getUDAs!(SteamAPI_ISteamUserStats_FindLeaderboard, SteamCallResult)[0].Result` is
  `LeaderboardFindResult_t`; `SteamCallback!(T...)` marks functions that make Steam post
  the callbacks `T` (`.Callbacks`, or `.Callback` when there is one).
- **C++ callback interfaces** the application implements (`ISteamMatchmakingServerListResponse`,
  `...PingResponse`, `...PlayersResponse`, `...RulesResponse`, `...ServerFriendsResponse`,
  `CCallbackBase`, `ISteamNetworkingConnectionSignaling`,
  `ISteamNetworkingSignalingRecvContext`) are `extern (C++)` abstract classes; derive an
  `extern (C++)` class, keep the object alive while Steam holds it, and keep overrides `nothrow`.

## Modules

| Module                                  | Contents                                                                    |
| --------------------------------------- | --------------------------------------------------------------------------- |
| `steamworks`                            | Imports everything below.                                                   |
| `steamworks.loader`                     | `loadSteamworks`, `unloadSteamworks`, `SteamworksLoadStatus`.               |
| `steamworks.lifecycle`                  | `steamInit`, `steamGameServerInit`, shutdown, `steamRestartAppIfNecessary`. |
| `steamworks.accessors`                  | `SteamUser()`, `SteamFriends()`, ... and the `SteamGameServer*()` ones.     |
| `steamworks.dispatch`                   | `CallbackDispatcher`, `NogcCallbackDispatcher`, `CallbackSource`.           |
| `steamworks.matchmaking`                | Delegate-based `ISteamMatchmaking*Response` implementations.                |
| `steamworks.steamid`                    | `CSteamID` accessors, rendering and parsing.                                |
| `steamworks.networking`                 | Text for `SteamNetworkingIPAddr` and `SteamNetworkingIdentity`.             |
| `steamworks.strings`                    | `fromCString`, `idupCString`, `tempCString`.                                |
| `steamworks.raw`                        | The complete flat API (public imports of the modules below).                |
| `steamworks.raw.types`                  | Typedefs (`AppId_t`, `SteamAPICall_t`, function pointer types, ...).        |
| `steamworks.raw.consts`                 | Constants.                                                                  |
| `steamworks.raw.enums`                  | Enums and their unqualified enumerators.                                    |
| `steamworks.raw.structs`                | Plain structs.                                                              |
| `steamworks.raw.callbacks`              | Callback and call-result structs.                                           |
| `steamworks.raw.interfaces`             | Interface handles, version strings, C++ callback interfaces.                |
| `steamworks.raw.isteam*`, `steam_api`, `steam_gameserver`, `steam*types`, ... | Flat functions, one module per SDK header. |
| `steamworks.raw.steamid`                | `CSteamID`, `CGameID`.                                                      |
| `steamworks.raw.manual`                 | Hand-written union and C++ class types.                                     |
| `steamworks.raw.helpers`                | The header-inline init functions, `SteamClient`, `BIsHTTPStatusSuccess`, POP ID conversions. |
| `steamworks.raw.platform`               | `VALVE_CALLBACK_PACK`, `callbackAlign`, `packAlign`.                        |
| `steamworks.raw.attributes`             | `SteamCallResult`, `SteamCallback` UDAs.                                    |
| `steamworks.raw.symbols`                | The list of every bound function, used by the loader and tests.             |

## Deliberately not bound

- Exports the headers do not declare (legacy entry points): `GetHSteamPipe`, `GetHSteamUser`,
  `SteamAPI_InitAnonymousUser`, the exported `SteamClient` symbol (the D `SteamClient()` follows
  the header instead), `SteamGameServer_GetIPCCallCount`, `SteamGameServer_InitSafe` and the
  `g_pSteamClientGameServer` variable. They are listed in `steamworksUnboundExports`.
- `ISteamMusicRemote`, `ISteamGameCoordinator` and `ISteamAppTicket` have no flat API (their
  version strings are still provided); the PS3 headers are obsolete.
- C++-only conveniences: the `CCallback`/`CCallResult` templates (use the D dispatcher,
  `CCallbackBase` or manual dispatch), the `SteamUser()`-style inline accessors of the C++ API
  (the D layer provides equivalents), the `*Render` string helper classes, the
  `STEAM_CALLBACK`-style macros, and the `SteamNetworkingMessage_t::Get*` compatibility getters.
  Interface methods with no flat function (`ISteamClient::RunFrame` and other internal or
  deprecated methods) cannot be called from C. The `abiVerify` section of
  `tools/gen/overrides.json` lists every such header declaration with its reason.
- `SteamDatagramRelayAuthTicket` is opaque: the SDK only forward-declares it.
- The encrypted app ticket library (`sdkencryptedappticket`) is a separate library.

## Development

```sh
tools/fetch-sdk.sh          # SDK into ./sdk (gitignored; never committed)
tests/run.sh                # every check below, with dmd and ldc2
tools/format.sh [--check]   # dfmt 0.15.2 (built with dub if not installed)
tools/lint.sh               # D-Scanner with dscanner.ini
```

Run `ulimit -n 65536` first on macOS if dub runs out of file descriptors.

### Regenerating for a new SDK

```sh
STEAMWORKS_SDK=/path/to/new/sdk tools/fetch-sdk.sh   # after moving the old ./sdk away
tools/gen/generate.sh --sdk-version 1.xx             # regenerate source/steamworks/raw and tests/abi
tools/check-abi.sh                                   # verify; then tests/run.sh
```

Make the new version the generator's default (`sdkVersion` in `tools/gen/source/app.d`, which
`generate.sh --check` uses) and pin the new SDK's checksums in `tools/fetch-sdk.sh`.

`tools/gen` reads `steam_api.json` and scans the SDK headers for what the JSON lacks (the
`#pragma pack` in force for each struct, the defining header, interface version macros, header-only
functions and constants). `tools/gen/overrides.json` holds every correction and header-only
addition, each with the header it comes from and the reason; the headers are the ground truth.
Generated files start with a "do not edit" banner, and `tools/gen/generate.sh --check` fails if
any is stale. After regenerating, `tools/check-abi.sh` reports every declaration that changed
shape, appeared or disappeared; new header-only items need entries in `overrides.json`, and new
C++ callback interfaces or unions need hand-written definitions in `steamworks.raw.manual`. The
D layer's accessors (`steamworks.accessors`) name versioned accessors and may need updating when
interface versions change.

### ABI verification

`tools/check-abi.sh [step...]` runs every ABI and symbol check, one step at a time (`DCS`
selects the D compilers, default `dmd ldc2`):

- `generated`: the generated modules and ABI expectations are current.
- `probe` (`tests/abi/check.sh`): a clang probe's measurements of every size, member alignment,
  field offset, enumerator, constant, flat function signature and interface version string,
  checked against the bindings natively and for all eight targets (ldc2 cross-compilation), in
  both configurations.
- `native` (`tests/abi/native/run.sh`, macOS): the probe compiled and run natively (and as x86_64
  under Rosetta), compared value by value with a D program built with dmd and ldc2.
- `verify` (`steamworks-gen --verify`): `tests/abi/reflect/dump.d` makes the D compilers describe
  every declaration of `steamworks.raw` for each target, and the generator turns the description
  into C++ static_asserts compiled against the headers with clang: sizes, alignments and offsets,
  exact field, alias and signature types (`long` and `long long` compare by size), enumerator and
  constant values, vtable slots (Itanium and MSVC order) and `extern (C++)`/`extern (C)` linkage.
  It compares clang's AST and macro table with the description in both directions, so a header
  declaration missing from D, or a D declaration missing from the headers, fails unless the
  `abiVerify` section of `tools/gen/overrides.json` justifies it. `tests/abi/reflect/linkrefs.d`
  then shows, for every target, that the linked configuration references exactly the declared
  functions under the names the target's `libsteam_api` (or import library) exports.
- `exports` (`tests/exports/check.sh`): every redistributable library's export table (including
  the DLLs) against the bound functions.
- `cabi` (`tests/cabi/run.sh`): calls into clang-compiled stand-ins of the functions that pass
  structs by value, checking the calling convention natively (and x86_64 under Rosetta on Apple
  silicon).

Other tests: `tests/smoke` and `tests/layer` run the raw API and the D layer against the real
library without a Steam client (symbol resolution, initialization failures, the library's struct
helpers, C++ virtual calls from the library into D, callback registration); `tests/vtable/run.sh`
calls the D response classes from C++ through the SDK's own class declarations; the dispatcher's
unit tests drive it with a fake `CallbackSource`.

### Continuous integration

`.github/workflows/ci.yml` runs the unit tests in both configurations, the smoke and D-layer
tests, and builds every example on Linux and Windows with the latest dmd and LDC and on macOS with
LDC (dmd's macOS Phobos archive does not link with the current Xcode linker); the full
ABI verification on macOS (whose LLVM tools read every platform's binaries); the native ABI checks
on Linux with both compilers; and the format and lint checks. It downloads the SDK with
`tools/fetch-sdk.sh`.

## License

The bindings, generator, tests and examples are licensed under the
[Boost Software License 1.0](LICENSE).

The Steamworks SDK, its headers and its redistributable libraries are the property of Valve
Corporation, licensed under the
[Steamworks SDK Access Agreement](https://partner.steamgames.com/documentation/sdk_access_agreement).
They are not part of this repository or of the dub package; obtain them from Valve and follow
that agreement when you redistribute `libsteam_api` with your game.

Steam and Steamworks are trademarks or registered trademarks of Valve Corporation. This project is
not affiliated with, endorsed by or sponsored by Valve.
