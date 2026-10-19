/// The inline functions of steam_api.h, steam_gameserver.h, isteamclient.h,
/// steamhttpenums.h and steamnetworkingtypes.h, which the library does not
/// export.
module steamworks.raw.helpers;

import steamworks.raw.enums : EHTTPStatusCode, ESteamAPIInitResult, EServerMode;
import steamworks.raw.interfaces;
import steamworks.raw.steam_api;
import steamworks.raw.steam_gameserver;
import steamworks.raw.types : SteamErrMsg, SteamNetworkingPOPID;

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

/// Returns the global ISteamClient interface (`STEAMCLIENT_INTERFACE_VERSION`);
/// with the `SteamworksDynamic` version, null while the library is not loaded.
///
/// Mirrors the inline `SteamClient` accessor of isteamclient.h.
ISteamClient* SteamClient() nothrow @nogc
{
    version (SteamworksDynamic)
        if (SteamInternal_CreateInterface is null)
            return null;
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

/// Converts a 3- or 4-character data center (POP) code such as `"iad"` to the
/// `SteamNetworkingPOPID` that ISteamNetworkingUtils' GetPOPList,
/// GetPingToDataCenter and GetDirectPingToPOP use. `"abc"` packs as
/// `0x00aabbcc` and `"abcd"` as `0xddaabbcc`; bytes after the terminator of a
/// shorter string are not read, and the empty string gives 0.
///
/// Mirrors the inline `CalculateSteamNetworkingPOPIDFromString` of
/// steamnetworkingtypes.h.
SteamNetworkingPOPID CalculateSteamNetworkingPOPIDFromString(const(char)* pszCode) @system pure nothrow @nogc
{
    SteamNetworkingPOPID result = cast(uint) cast(ubyte) pszCode[0] << 16U;
    if (result && pszCode[1])
    {
        result |= cast(uint) cast(ubyte) pszCode[1] << 8U;
        if (pszCode[2])
            result |= cast(uint) cast(ubyte) pszCode[2] | (cast(uint) cast(ubyte) pszCode[3] << 24U);
    }
    return result;
}

/// Writes the code of a `SteamNetworkingPOPID` to `szCode` with a terminating
/// NUL: 3 characters and two NULs for a 3-character code, otherwise 4 and one.
///
/// Mirrors the inline template `GetSteamNetworkingLocationPOPStringFromID` of
/// steamnetworkingtypes.h.
void GetSteamNetworkingLocationPOPStringFromID(size_t N)(SteamNetworkingPOPID id, ref char[N] szCode) @safe pure nothrow @nogc
{
    static assert(N >= 5, "Fixed-size buffer not big enough to hold SDR POP ID");
    szCode[0] = cast(char)(id >> 16U);
    szCode[1] = cast(char)(id >> 8U);
    szCode[2] = cast(char) id;
    szCode[3] = cast(char)(id >> 24U);
    szCode[4] = 0;
}

unittest
{
    // A buffer without room for 4 characters and the NUL is rejected.
    static assert(!__traits(compiles, {
            char[4] small;
            GetSteamNetworkingLocationPOPStringFromID(1, small);
        }));
    static assert(__traits(compiles, {
            char[5] code;
            GetSteamNetworkingLocationPOPStringFromID(1, code);
        }));
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
