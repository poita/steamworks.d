# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project uses
[Semantic Versioning](https://semver.org/spec/v2.0.0.html). Each release names the Steamworks SDK
release it is generated from; moving to a new SDK release is a minor version (or a major one when
it removes or changes existing declarations).

## [Unreleased]

### Added

- Complete bindings to the Steamworks SDK 1.65 flat C API (`steamworks.raw`): all 1057 functions
  the headers declare and `libsteam_api` exports, the 34 interfaces with their accessors and
  version strings, 196 callback structs, the plain structs, 115 enums, 163 constants and 78
  typedefs, with Valve's names.
- Callback struct packing for every platform (`VALVE_CALLBACK_PACK` 4 on Linux, macOS and
  Android, 8 on Windows), zero-initialized structs, `CSteamID`/`CGameID` with their C++ inline
  members, the header-inline functions (`SteamAPI_InitEx`, `SteamGameServer_InitEx`,
  `SteamClient`, the POP ID conversions, ...), `c_char` for C's by-value `char` with the
  target's signedness, and `extern (C++)` classes for the C++ callback interfaces
  (`ISteamMatchmaking*Response`, `CCallbackBase`, the networking signaling interfaces).
- `SteamCallResult` and `SteamCallback` attributes on every asynchronous function.
- Two dub configurations: `dynamic` (default; `loadSteamworks()` binds the library at run time)
  and `linked`.
- A D layer: `steamInit`/`steamGameServerInit` with Steam's error message, the C++-named
  interface accessors (null while the library is missing), `CallbackDispatcher` and
  `NogcCallbackDispatcher` for callbacks and call results over manual dispatch (`@safe` with
  `@safe` handlers, and safe to tear down from a handler), delegate-based server browser
  responses (including `ServerFriendsResponse` for `ServerFriends`), Steam ID rendering and
  parsing, network address and identity text conversions, and C string helpers.
- The generator (`tools/gen`) with its documented overrides, and the ABI verification against the
  SDK headers and libraries for macOS, Windows, Linux and Android (`tools/check-abi.sh`).
- Examples: `dispatcher`, `manual-dispatch`, `achievements`, `matchmaking`, `networking` and
  `game-server`.
- GitHub Actions CI on Linux, macOS and Windows with dmd and LDC.

### Changed

- Generated from SDK 1.65 instead of 1.64; ship the 1.65 `libsteam_api`. Compared with 1.64:
  - New interface versions and accessors: `SteamUtils011`, `SteamInput007`,
    `SteamMatchMakingServers003`, `SteamNetworkingSockets013` (`SteamAPI_SteamUtils_v011`, ...).
  - `SteamAPI_ISteamNetworkingSockets_SendMessages` takes a mutable `SteamNetworkingMessage_t**`
    (the library may clear the entries it queued) and a trailing `bool bDeleteFailedMessages`.
  - New functions: `ISteamUtils::IsRunningOnSteamHardware`, `GetSteamHardwareDefaultConfig` and
    `IsRunningUnderProton` (replacing the removed `IsSteamRunningOnSteamDeck`);
    `ISteamApps::SetGamePerformanceSetting` and `SetGameRenderResolution`;
    `ISteamMatchmakingServers::ServerFriends` with the C++ callback interface
    `ISteamMatchmakingServerFriendsResponse`; `servernetadr_t` and `gameserveritem_t` `IsEqualTo`.
  - New enums `ESteamHardwareType`, `ESteamHardwareDefaultConfig` and `EGamePerformanceSetting`;
    Switch 2, Steam Controller (2026) and Steam Frame controller origins and input types (and
    `k_ESteamInputType_SteamOSHandheld`); more
    `ESteamControllerPad` values; `EUGCQuery` ranked by parent items and collections.
  - `gameserveritem_t` ends with `m_nCurrentFriendCount` and `m_nTotalFriendCount`;
    `k_cchDeveloperMetadataMax` is 10000.
  - `CGameID`: the `(id, type)` constructor, `AppID`/`ModID` that read a shortcut's ID, and no
    `k_EGameIDTypeP2P` or `IsP2PFile`. `SteamNetworkingConfigValue_t.SetString` tags the value as
    `k_ESteamNetworkingConfig_String`.
- `tools/fetch-sdk.sh` fetches SDK 1.65 from a pinned steamworks-rs commit and verifies the
  extracted files; `STEAMWORKS_SDK_VERSION=1.64` keeps the crates.io copy of 1.64.

[Unreleased]: https://github.com/Poita/steamworks.d/commits/dev
