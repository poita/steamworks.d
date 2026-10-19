# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). Each release names the Steamworks SDK
release it is generated from; moving to a new SDK release is a minor version (or a major one when
it removes or changes existing declarations).

## [Unreleased]

### Added

- Complete bindings to the Steamworks SDK 1.64 flat C API (`steamworks.raw`): all 1047 functions
  the headers declare and `libsteam_api` exports, the 33 interfaces with their accessors and
  version strings, 196 callback structs, the plain structs, 112 enums, 163 constants and 78
  typedefs, with Valve's names.
- Callback struct packing for every platform (`VALVE_CALLBACK_PACK` 4 on Linux, macOS and
  Android, 8 on Windows), zero-initialized structs, `CSteamID`/`CGameID` with their C++ inline
  members, the header-inline functions (`SteamAPI_InitEx`, `SteamGameServer_InitEx`,
  `SteamClient`, ...), and `extern (C++)` classes for the C++ callback interfaces
  (`ISteamMatchmaking*Response`, `CCallbackBase`, the networking signaling interfaces).
- `SteamCallResult` and `SteamCallback` attributes on every asynchronous function.
- Two dub configurations: `dynamic` (default; `loadSteamworks()` binds the library at run time)
  and `linked`.
- A D layer: `steamInit`/`steamGameServerInit` with Steam's error message, the C++-named
  interface accessors, `CallbackDispatcher` and `NogcCallbackDispatcher` for callbacks and call
  results over manual dispatch, delegate-based server browser responses, Steam ID rendering and
  parsing, network address and identity text conversions, and C string helpers.
- The generator (`tools/gen`) with its documented overrides, and the ABI verification against the
  SDK headers and libraries for macOS, Windows, Linux and Android (`tools/check-abi.sh`).
- Examples: `dispatcher`, `manual-dispatch`, `achievements`, `matchmaking`, `networking` and
  `game-server`.
- GitHub Actions CI on Linux, macOS and Windows with dmd and LDC.

[Unreleased]: https://github.com/Poita/steamworks.d/commits/dev
