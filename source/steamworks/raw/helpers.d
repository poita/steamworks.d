/// The inline functions of steam_api.h, steam_gameserver.h, isteamclient.h
/// and steamhttpenums.h, which the library does not export.
module steamworks.raw.helpers;

import steamworks.raw.enums : EHTTPStatusCode, ESteamAPIInitResult, EServerMode;
import steamworks.raw.interfaces;
import steamworks.raw.steam_api;
import steamworks.raw.steam_gameserver;
import steamworks.raw.types : SteamErrMsg;

/// Interface versions SteamAPI_InitEx asks the client to support, as the
/// NUL-separated, double-NUL-terminated list steam_api.h builds.
enum string steamAPIInterfaceVersions = STEAMUTILS_INTERFACE_VERSION ~ "\0" ~ STEAMNETWORKINGUTILS_INTERFACE_VERSION
    ~ "\0" ~ STEAMAPPS_INTERFACE_VERSION ~ "\0" ~ STEAMCONTROLLER_INTERFACE_VERSION ~ "\0"
    ~ STEAMFRIENDS_INTERFACE_VERSION
    ~ "\0" ~ STEAMHTMLSURFACE_INTERFACE_VERSION ~ "\0" ~ STEAMHTTP_INTERFACE_VERSION
    ~ "\0" ~ STEAMINPUT_INTERFACE_VERSION ~ "\0" ~ STEAMINVENTORY_INTERFACE_VERSION ~ "\0"
    ~ STEAMMATCHMAKINGSERVERS_INTERFACE_VERSION ~ "\0" ~ STEAMMATCHMAKING_INTERFACE_VERSION ~ "\0"
    ~ STEAMMUSIC_INTERFACE_VERSION
    ~ "\0" ~ STEAMNETWORKINGMESSAGES_INTERFACE_VERSION ~ "\0"
    ~ STEAMNETWORKINGSOCKETS_INTERFACE_VERSION ~ "\0" ~ STEAMNETWORKING_INTERFACE_VERSION ~ "\0"
    ~ STEAMPARENTALSETTINGS_INTERFACE_VERSION ~ "\0" ~ STEAMPARTIES_INTERFACE_VERSION ~ "\0"
    ~ STEAMREMOTEPLAY_INTERFACE_VERSION
    ~ "\0" ~ STEAMREMOTESTORAGE_INTERFACE_VERSION ~ "\0" ~ STEAMSCREENSHOTS_INTERFACE_VERSION
    ~ "\0" ~ STEAMUGC_INTERFACE_VERSION ~ "\0" ~ STEAMUSERSTATS_INTERFACE_VERSION ~ "\0"
    ~ STEAMUSER_INTERFACE_VERSION ~ "\0" ~ STEAMVIDEO_INTERFACE_VERSION ~ "\0" ~ "\0";

/// Interface versions SteamGameServer_InitEx asks the client to support.
enum string steamGameServerInterfaceVersions = STEAMUTILS_INTERFACE_VERSION ~ "\0"
    ~ STEAMNETWORKINGUTILS_INTERFACE_VERSION ~ "\0" ~ STEAMGAMESERVER_INTERFACE_VERSION
    ~ "\0" ~ STEAMGAMESERVERSTATS_INTERFACE_VERSION ~ "\0" ~ STEAMHTTP_INTERFACE_VERSION
    ~ "\0" ~ STEAMINVENTORY_INTERFACE_VERSION ~ "\0" ~ STEAMNETWORKING_INTERFACE_VERSION
    ~ "\0" ~ STEAMNETWORKINGMESSAGES_INTERFACE_VERSION ~ "\0"
    ~ STEAMNETWORKINGSOCKETS_INTERFACE_VERSION ~ "\0" ~ STEAMUGC_INTERFACE_VERSION ~ "\0" ~ "\0";

/// Initializes the Steam API, checking that the running client supports the
/// interface versions these bindings were generated for. On failure, a
/// non-localized reason is written to `*pOutErrMsg` when it is not null.
///
/// Mirrors the inline `SteamAPI_InitEx` of steam_api.h.
ESteamAPIInitResult SteamAPI_InitEx(SteamErrMsg* pOutErrMsg) nothrow @nogc
{
    return SteamInternal_SteamAPI_Init(steamAPIInterfaceVersions.ptr, pOutErrMsg);
}

/// Initializes the Steam API; returns whether it succeeded.
///
/// Mirrors the inline `SteamAPI_Init` of steam_api.h.
bool SteamAPI_Init() nothrow @nogc
{
    return SteamAPI_InitEx(null) == ESteamAPIInitResult.k_ESteamAPIInitResult_OK;
}

/// Initializes the game server interfaces. `unIP` is usually 0; pass
/// STEAMGAMESERVER_QUERY_PORT_SHARED as `usQueryPort` to share the game port.
///
/// Mirrors the inline `SteamGameServer_InitEx` of steam_gameserver.h.
ESteamAPIInitResult SteamGameServer_InitEx(uint unIP, ushort usGamePort, ushort usQueryPort,
        EServerMode eServerMode, const(char)* pchVersionString, SteamErrMsg* pOutErrMsg) nothrow @nogc
{
    return SteamInternal_GameServer_Init_V2(unIP, usGamePort, usQueryPort, eServerMode,
            pchVersionString, steamGameServerInterfaceVersions.ptr, pOutErrMsg);
}

/// Initializes the game server interfaces; returns whether it succeeded.
///
/// Mirrors the inline `SteamGameServer_Init` of steam_gameserver.h.
bool SteamGameServer_Init(uint unIP, ushort usGamePort, ushort usQueryPort, EServerMode eServerMode,
        const(char)* pchVersionString) nothrow @nogc
{
    return SteamGameServer_InitEx(unIP, usGamePort, usQueryPort, eServerMode, pchVersionString, null) == ESteamAPIInitResult
        .k_ESteamAPIInitResult_OK;
}

/// Frees the API's thread-local memory for the calling thread.
///
/// Mirrors the inline `SteamGameServer_ReleaseCurrentThreadMemory` of steam_gameserver.h.
void SteamGameServer_ReleaseCurrentThreadMemory() nothrow @nogc
{
    SteamAPI_ReleaseCurrentThreadMemory();
}

/// Returns the global ISteamClient interface (`STEAMCLIENT_INTERFACE_VERSION`).
///
/// Mirrors the inline `SteamClient` accessor of isteamclient.h.
ISteamClient* SteamClient() nothrow @nogc
{
    return cast(ISteamClient*) SteamInternal_CreateInterface(STEAMCLIENT_INTERFACE_VERSION.ptr);
}

/// Returns the ISteamClient interface for game servers (the same object).
///
/// Mirrors the inline `SteamGameServerClient` accessor of isteamclient.h.
ISteamClient* SteamGameServerClient() nothrow @nogc
{
    return SteamClient();
}

/// Whether an HTTP status code is in the 2xx success range.
///
/// Mirrors the inline `BIsHTTPStatusSuccess` of steamhttpenums.h.
bool BIsHTTPStatusSuccess(EHTTPStatusCode eStatus) @safe pure nothrow @nogc
{
    return eStatus >= 200 && eStatus <= 299;
}

unittest
{
    assert(BIsHTTPStatusSuccess(EHTTPStatusCode.k_EHTTPStatusCode200OK));
    assert(BIsHTTPStatusSuccess(cast(EHTTPStatusCode) 299));
    assert(!BIsHTTPStatusSuccess(EHTTPStatusCode.k_EHTTPStatusCode404NotFound));
    assert(!BIsHTTPStatusSuccess(EHTTPStatusCode.k_EHTTPStatusCode100Continue));
}

unittest
{
    // Each list is NUL separated and ends with an empty entry.
    static assert(steamAPIInterfaceVersions[$ - 2 .. $] == "\0\0");
    static assert(steamGameServerInterfaceVersions[$ - 2 .. $] == "\0\0");
    import std.algorithm : count;

    static assert(steamAPIInterfaceVersions.count('\0') == 25);
    static assert(steamGameServerInterfaceVersions.count('\0') == 11);
}
