/// Starting and stopping the Steam API, for games (the client) and for game
/// servers.
///
/// ---
/// import steamworks;
///
/// if (loadSteamworks() != SteamworksLoadStatus.success)
///     return;                         // no Steam library: run without Steam
/// if (steamRestartAppIfNecessary(480))
///     return;                         // Steam relaunches the game
/// const init = steamInit();
/// if (!init)
/// {
///     writeln("Steam unavailable: ", init.message);
///     return;
/// }
/// scope (exit) steamShutdown();
/// ---
module steamworks.lifecycle;

import core.stdc.string : memcpy;

import steamworks.raw.enums : EServerMode, ESteamAPIInitResult;
import steamworks.raw.helpers : SteamAPI_InitEx, SteamGameServer_InitEx;
import steamworks.raw.steam_api;
import steamworks.raw.steam_gameserver;
import steamworks.raw.types : AppId_t, SteamErrMsg;
import steamworks.strings : fromCString, tempCString;

/// How callbacks and call results reach the application.
enum SteamDispatchMode
{
    /// `SteamAPI_ManualDispatch_Init` is called before initializing, and the
    /// application pumps callbacks itself, normally with a
    /// `steamworks.dispatch.CallbackDispatcher`.
    manual,
    /// Steam's own dispatch (`SteamAPI_RunCallbacks` with registered
    /// `CCallbackBase` objects) is left in place.
    automatic,
}

/// Outcome of `steamInit` or `steamGameServerInit`. Converts to `true` on
/// success.
struct SteamInitResult
{
    /// What the initialization reported.
    ESteamAPIInitResult result = ESteamAPIInitResult.k_ESteamAPIInitResult_FailedGeneric;
    /// Steam's non-localized explanation of a failure; empty on success.
    SteamErrMsg errMsg = '\0';

    /// Whether initialization succeeded.
    bool ok() const @safe pure nothrow @nogc
    {
        return result == ESteamAPIInitResult.k_ESteamAPIInitResult_OK;
    }

    /// ditto
    bool opCast(T : bool)() const @safe pure nothrow @nogc
    {
        return ok;
    }

    /// The text of `errMsg`.
    const(char)[] message() const return @safe pure nothrow @nogc
    {
        return fromCString(errMsg);
    }

    private static SteamInitResult failure(ESteamAPIInitResult result, string msg) @trusted pure nothrow @nogc
    {
        SteamInitResult r;
        r.result = result;
        enum size_t capacity = SteamErrMsg.sizeof - 1;
        const n = msg.length < capacity ? msg.length : capacity;
        memcpy(r.errMsg.ptr, msg.ptr, n);
        return r;
    }
}

/// Thrown by `steamInitOrThrow` and `steamGameServerInitOrThrow`.
class SteamInitException : Exception
{
    /// What the initialization reported.
    ESteamAPIInitResult result;

    /// Creates the exception from a failed `SteamInitResult`.
    this(const ref SteamInitResult r, string file = __FILE__, size_t line = __LINE__) @safe pure nothrow
    {
        result = r.result;
        super(r.message.length ? r.message.idup : "Steam initialization failed", file, line);
    }
}

private enum string notLoaded = "the Steamworks library is not loaded; call loadSteamworks() first";

private __gshared bool manualDispatchEnabled;

private void selectDispatch(SteamDispatchMode mode) nothrow @nogc
{
    if (mode == SteamDispatchMode.manual && !manualDispatchEnabled)
    {
        SteamAPI_ManualDispatch_Init();
        manualDispatchEnabled = true;
    }
}

/// Initializes the Steam API for the running game (`SteamAPI_InitEx`),
/// checking that the user's Steam client supports every interface version
/// these bindings call. With `SteamDispatchMode.manual` (the default),
/// manual callback dispatch is selected first.
///
/// With the "dynamic" configuration, a library that `loadSteamworks` has not
/// loaded gives `k_ESteamAPIInitResult_FailedGeneric` and an explanatory
/// message rather than a crash.
SteamInitResult steamInit(SteamDispatchMode mode = SteamDispatchMode.manual) nothrow @nogc
{
    version (SteamworksDynamic)
    {
        if (SteamInternal_SteamAPI_Init is null || SteamAPI_ManualDispatch_Init is null)
            return SteamInitResult.failure(ESteamAPIInitResult.k_ESteamAPIInitResult_FailedGeneric, notLoaded);
    }
    selectDispatch(mode);
    SteamInitResult r;
    r.result = SteamAPI_InitEx(&r.errMsg);
    return r;
}

/// Like `steamInit`, but throws a `SteamInitException` carrying Steam's
/// message on failure.
void steamInitOrThrow(SteamDispatchMode mode = SteamDispatchMode.manual)
{
    const r = steamInit(mode);
    if (!r)
        throw new SteamInitException(r);
}

/// Shuts the Steam API down (`SteamAPI_Shutdown`). Does nothing when the
/// library is not loaded.
void steamShutdown() nothrow @nogc
{
    version (SteamworksDynamic)
        if (SteamAPI_Shutdown is null)
            return;
    SteamAPI_Shutdown();
}

/// Asks Steam to relaunch the game if it was started outside Steam
/// (`SteamAPI_RestartAppIfNecessary`). Returns true when the process should
/// exit at once. Call it before `steamInit`. Returns false (keep running)
/// when the library is not loaded.
bool steamRestartAppIfNecessary(AppId_t ownAppID) nothrow @nogc
{
    version (SteamworksDynamic)
        if (SteamAPI_RestartAppIfNecessary is null)
            return false;
    return SteamAPI_RestartAppIfNecessary(ownAppID);
}

/// Initializes the game server interfaces (`SteamGameServer_InitEx`).
///
/// Params:
///   ip = IPv4 address to bind, in host order; 0 binds every address.
///   gamePort = the port clients connect to for gameplay.
///   queryPort = the port for server browser queries, or
///       `STEAMGAMESERVER_QUERY_PORT_SHARED` to share the game port.
///   serverMode = authentication and VAC mode.
///   versionString = the server version, "x.x.x.x"; used by the master
///       server to detect outdated servers.
///   mode = callback dispatch, as for `steamInit`.
SteamInitResult steamGameServerInit(uint ip, ushort gamePort, ushort queryPort, EServerMode serverMode,
        scope const(char)[] versionString, SteamDispatchMode mode = SteamDispatchMode.manual) nothrow @nogc
{
    version (SteamworksDynamic)
    {
        if (SteamInternal_GameServer_Init_V2 is null || SteamAPI_ManualDispatch_Init is null)
            return SteamInitResult.failure(ESteamAPIInitResult.k_ESteamAPIInitResult_FailedGeneric, notLoaded);
    }
    auto ver = tempCString(versionString);
    if (ver.ptr is null)
        return SteamInitResult.failure(ESteamAPIInitResult.k_ESteamAPIInitResult_FailedGeneric, "out of memory");
    selectDispatch(mode);
    SteamInitResult r;
    r.result = SteamGameServer_InitEx(ip, gamePort, queryPort, serverMode, ver.ptr, &r.errMsg);
    return r;
}

/// Like `steamGameServerInit`, but throws a `SteamInitException` on failure.
void steamGameServerInitOrThrow(uint ip, ushort gamePort, ushort queryPort, EServerMode serverMode,
        scope const(char)[] versionString, SteamDispatchMode mode = SteamDispatchMode.manual)
{
    const r = steamGameServerInit(ip, gamePort, queryPort, serverMode, versionString, mode);
    if (!r)
        throw new SteamInitException(r);
}

/// Shuts the game server interfaces down (`SteamGameServer_Shutdown`). Does
/// nothing when the library is not loaded.
void steamGameServerShutdown() nothrow @nogc
{
    version (SteamworksDynamic)
        if (SteamGameServer_Shutdown is null)
            return;
    SteamGameServer_Shutdown();
}

unittest
{
    SteamInitResult r;
    assert(!r.ok && !r);
    assert(r.message.length == 0);
    r.result = ESteamAPIInitResult.k_ESteamAPIInitResult_OK;
    assert(r.ok && r);
}

unittest
{
    const r = SteamInitResult.failure(ESteamAPIInitResult.k_ESteamAPIInitResult_NoSteamClient, "no client");
    assert(r.result == ESteamAPIInitResult.k_ESteamAPIInitResult_NoSteamClient);
    assert(r.message == "no client");
    auto e = new SteamInitException(r);
    assert(e.result == ESteamAPIInitResult.k_ESteamAPIInitResult_NoSteamClient);
    assert(e.msg == "no client");
}

unittest
{
    char[2000] long_ = 'x';
    const r = SteamInitResult.failure(ESteamAPIInitResult.k_ESteamAPIInitResult_FailedGeneric, long_.idup);
    assert(r.message.length + 1 == SteamErrMsg.sizeof);
}

version (SteamworksDynamic) unittest
{
    import steamworks.loader : isSteamworksLoaded;

    if (isSteamworksLoaded())
        return;
    const r = steamInit();
    assert(r.result == ESteamAPIInitResult.k_ESteamAPIInitResult_FailedGeneric);
    assert(r.message == notLoaded);
    const s = steamGameServerInit(0, 27_015, 27_016, EServerMode.eServerModeNoAuthentication, "1.0.0.0");
    assert(!s && s.message == notLoaded);
    assert(!steamRestartAppIfNecessary(480));
    steamShutdown();
    steamGameServerShutdown();
}

version (SteamworksDynamic) unittest
{
    import std.exception : assertThrown;
    import steamworks.loader : isSteamworksLoaded;

    if (isSteamworksLoaded())
        return;
    assertThrown!SteamInitException(steamInitOrThrow());
    assertThrown!SteamInitException(steamGameServerInitOrThrow(0, 1, 2, EServerMode.eServerModeNoAuthentication, "1"));
}
