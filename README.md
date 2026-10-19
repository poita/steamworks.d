# steamworks.d

D bindings for the [Steamworks SDK](https://partner.steamgames.com/doc/sdk) flat C API, generated from
SDK 1.65 and checked against the SDK headers for every platform Valve ships `libsteam_api` for.

- **Complete.** Every function the SDK headers declare and `libsteam_api` exports (1047), all 33
  interfaces with their accessors and version strings, 196 callback structs, the plain structs,
  112 enums, 141 constants and 78 typedefs. Nothing is a demo subset.
- **Faithful.** Valve's C and C++ names throughout, so the
  [Steamworks API reference](https://partner.steamgames.com/doc/api) applies as written.
- **ABI-checked.** A clang probe measures every size, member alignment, field offset, enumerator,
  constant, flat function signature and interface version string on macOS (arm64, x86_64), Windows
  (x64, x86), Linux (x86_64, i686, arm64) and Android (arm64); the bindings are verified against
  all of them at compile time with dmd and ldc2.
- **Two linking modes.** Load `libsteam_api` at runtime (the default) or link it directly, with
  the same code.
- **Standalone.** No dependencies beyond druntime; every function is `nothrow @nogc`.

The package exposes the raw flat API (`steamworks.raw`). It is the foundation a higher-level D
API can be built on, and usable directly by anyone who knows the C API.

## Installation

```sdl
dependency "steamworks" version="~>0.1.0"
```

(Until the package is published on code.dlang.org, use a path or git dependency.)

The Steamworks SDK itself is not included. Download it from the
[Steamworks partner site](https://partner.steamgames.com/downloads/list) and ship the library for
each platform next to your executable:

| Platform        | File (from `sdk/redistributable_bin`) |
| --------------- | ------------------------------------- |
| Windows x64     | `win64/steam_api64.dll`               |
| Windows x86     | `steam_api.dll`                       |
| macOS           | `osx/libsteam_api.dylib` (universal)  |
| Linux x86_64    | `linux64/libsteam_api.so`             |
| Linux i686      | `linux32/libsteam_api.so`             |
| Linux arm64     | `linuxarm64/libsteam_api.so`          |
| Android arm64   | `androidarm64/libsteam_api.so`        |

## Configurations

**`dynamic`** (default): every flat function is a `__gshared` function pointer that
`loadSteamworks()` binds at runtime. Nothing links against `libsteam_api`, so the package builds
without the SDK present, and a game can run (and fall back gracefully) where the library is
missing, such as DRM-free builds of the same binary. This is the recommended mode.

```d
import steamworks;

const status = loadSteamworks();  // next to the executable, then the system search path
// or loadSteamworks("path/to/libsteam_api.so")
if (status != SteamworksLoadStatus.success)
    writeln("no Steam: ", steamworksLoadError());
```

`loadSteamworks` returns `success`, `libraryNotFound`, or `missingSymbols` (an older library:
the functions it has are bound and the rest stay `null`; see `steamworksMissingSymbolCount`).
`unloadSteamworks()` releases the library after `SteamAPI_Shutdown()`.

**`linked`**: functions are plain `extern (C)` declarations and the library is linked at build
time. Select it and tell the linker where the library is:

```sdl
dependency "steamworks" version="~>0.1.0"
subConfiguration "steamworks" "linked"
lflags "-L/path/to/sdk/redistributable_bin/linux64" platform="linux"
lflags "-L/path/to/sdk/redistributable_bin/osx" platform="osx"
lflags "/LIBPATH:C:\\path\\to\\sdk\\redistributable_bin\\win64" platform="windows-x86_64"
```

In this mode `loadSteamworks()` simply returns `success`, so code written for the dynamic mode
works unchanged. On macOS the library's install name is `@loader_path/libsteam_api.dylib`, so it
must sit next to the executable at runtime; on Linux add an rpath such as `$ORIGIN`.

## Usage

```d
import core.stdc.string : strlen;
import std.stdio : writefln;
import steamworks;

void main()
{
    if (loadSteamworks() != SteamworksLoadStatus.success)
        return;

    SteamAPI_ManualDispatch_Init();
    SteamErrMsg err = 0;
    if (SteamAPI_InitEx(&err) != k_ESteamAPIInitResult_OK)
    {
        writefln("Steam unavailable: %s", err.ptr[0 .. strlen(err.ptr)]);
        return;
    }
    scope (exit) SteamAPI_Shutdown();

    const id = CSteamID(SteamAPI_ISteamUser_GetSteamID(SteamAPI_SteamUser()));
    const name = SteamAPI_ISteamFriends_GetPersonaName(SteamAPI_SteamFriends());
    writefln("%s (account %s)", name[0 .. strlen(name)], id.GetAccountID());

    const pipe = SteamAPI_GetHSteamPipe();
    foreach (frame; 0 .. 600)
    {
        SteamAPI_ManualDispatch_RunFrame(pipe);
        CallbackMsg_t msg;
        while (SteamAPI_ManualDispatch_GetNextCallback(pipe, &msg))
        {
            if (msg.m_iCallback == PersonaStateChange_t.k_iCallback)
            {
                auto change = cast(PersonaStateChange_t*) msg.m_pubParam;
                // ...
            }
            SteamAPI_ManualDispatch_FreeLastCallback(pipe);
        }
        // render a frame
    }
}
```

`examples/manual-dispatch` is a complete program, including an asynchronous call result. During
development put a `steam_appid.txt` with your app ID (480, Spacewar, for testing) in the working
directory.

## How the C API maps to D

- **Functions** keep their flat names: `SteamAPI_<Interface>_<Method>(self, ...)`. Interface
  pointers come from the accessors, e.g. `SteamAPI_SteamUser()` (the unversioned inline accessor of
  `steam_api_flat.h`, forwarding to the exported `SteamAPI_SteamUser_v023()`) or
  `SteamAPI_SteamGameServerNetworking()`.
- **Header-inline functions** the library does not export are provided in D:
  `SteamAPI_Init`, `SteamAPI_InitEx`, `SteamGameServer_Init`, `SteamGameServer_InitEx`,
  `SteamGameServer_ReleaseCurrentThreadMemory`, `SteamClient` and `SteamGameServerClient`, plus the
  trivial inline members of `CSteamID`, `CGameID`, `SteamIPAddress_t`, `SteamNetworkingIPAddr`,
  `SteamNetworkingIdentity` and `SteamNetworkingConfigValue_t`.
- **Steam IDs** cross the flat API as `uint64_steamid` (and `uint64_gameid`); `CSteamID` and
  `CGameID` are 8-byte, byte-aligned structs with the C++ accessors (`GetAccountID`,
  `GetEAccountType`, `IsValid`, ...), used in callback structs.
- **Enums** are D enums with the C++ underlying type. Every enumerator is also available
  unqualified, as in C++: `k_EResultOK` and `EResult.k_EResultOK` are the same constant.
- **C++ references** (`const SteamNetworkingIPAddr &`) are `ref const(SteamNetworkingIPAddr)`;
  strings are `const(char)*`; fixed buffers such as `SteamErrMsg` are static arrays passed by
  pointer.
- **Callback structs** carry `enum int k_iCallback`. Their fields use
  `align(callbackAlign!T)`, reproducing `VALVE_CALLBACK_PACK` (4 on Linux, macOS and Android,
  8 on Windows), and byte-packed structs use `align(1)`, so layouts match the platform's C++
  compiler.
- **Structs** default-initialize to all zero bytes, like C++ value-initialization (D would
  otherwise fill `char` arrays with `0xFF` and floats with NaN).
- **Asynchronous functions** carry their result type as a UDA:
  `getUDAs!(SteamAPI_ISteamUserStats_FindLeaderboard, SteamCallResult)[0].Result` is
  `LeaderboardFindResult_t`; `SteamCallback!T` marks functions that post a callback.
- **C++ callback interfaces** the application implements (`ISteamMatchmakingServerListResponse`,
  `...PingResponse`, `...PlayersResponse`, `...RulesResponse`, `CCallbackBase`,
  `ISteamNetworkingConnectionSignaling`, `ISteamNetworkingSignalingRecvContext`) are
  `extern (C++)` abstract classes; derive an `extern (C++)` class, keep the object alive while
  Steam holds it, and keep overrides `nothrow`. On Windows the compiler lays out the vtable as
  MSVC does.

## Modules

| Module                                  | Contents                                                                    |
| --------------------------------------- | --------------------------------------------------------------------------- |
| `steamworks`                            | Imports everything below.                                                   |
| `steamworks.loader`                     | `loadSteamworks`, `unloadSteamworks`, `SteamworksLoadStatus`.               |
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
| `steamworks.raw.helpers`                | The header-inline init functions and `SteamClient`.                         |
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
- `SteamDatagramRelayAuthTicket` is opaque: the SDK only forward-declares it.
- The encrypted app ticket library (`sdkencryptedappticket`) is a separate library.

## Development

```sh
tools/fetch-sdk.sh          # SDK into ./sdk (gitignored; never committed)
tools/gen/generate.sh       # regenerate source/steamworks/raw and the ABI expectations
tests/run.sh                # every check below, with dmd and ldc2
```

Generation needs dub, a D compiler, `clang++` (for the ABI probe) and `dfmt`.

- `tools/gen` reads `steam_api.json` and scans the SDK headers for what the JSON lacks (the
  `#pragma pack` in force for each struct, the defining header, interface version macros).
  `tools/gen/overrides.json` holds every correction and header-only addition, each with the header
  it comes from and the reason. Generated files start with a "do not edit" banner;
  `tools/gen/generate.sh --check` fails if any is stale.
- `tests/abi/check.sh` compiles the clang-measured expectations against the bindings natively and
  for all eight targets (ldc2 cross-compilation), in both configurations.
- `tests/exports/check.sh` compares the bindings with the export table of every redistributable
  library.
- `tests/cabi/run.sh` calls clang-compiled stand-ins of the functions that pass structs by value,
  checking the calling convention with dmd and ldc2 (and x86_64 under Rosetta on Apple silicon).
- `tests/smoke` runs against the real library without a Steam client: symbol resolution,
  initialization failure handling, the library's struct helpers, C++ virtual calls from the library
  into D, and callback registration.

## License

Boost Software License 1.0, see [LICENSE](LICENSE).

The Steamworks SDK is © Valve Corporation and distributed under the Steamworks SDK license; it is
not part of this repository. Steam and Steamworks are trademarks of Valve Corporation. This project
is not affiliated with Valve.
