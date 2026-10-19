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
    /// `SteamAPI_ManualDispatch_Init` is called once initialization succeeds
    /// (steam_api.h requires it after `SteamAPI_Init`), and the application
    /// pumps callbacks itself, normally with a
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
/// manual callback dispatch is selected once initialization succeeds.
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
    SteamInitResult r;
    r.result = SteamAPI_InitEx(&r.errMsg);
    if (r)
        selectDispatch(mode);
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
    manualDispatchEnabled = false;
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
    SteamInitResult r;
    r.result = SteamGameServer_InitEx(ip, gamePort, queryPort, serverMode, ver.ptr, &r.errMsg);
    if (r)
        selectDispatch(mode);
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
    manualDispatchEnabled = false;
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

version (SteamworksDynamic) version (unittest)
{
    private __gshared char[128] callLog;
    private __gshared size_t callLogLength;
    private __gshared ESteamAPIInitResult fakeInitResult;

    private void logCall(string call) nothrow @nogc
    {
        callLog[callLogLength .. callLogLength + call.length] = call[];
        callLogLength += call.length;
    }

    private const(char)[] lifecycleCalls() nothrow @nogc
    {
        return callLog[0 .. callLogLength];
    }

    private extern (C) ESteamAPIInitResult fakeClientInit(const(char)*, SteamErrMsg* err) nothrow @nogc
    {
        logCall("init;");
        if (fakeInitResult != ESteamAPIInitResult.k_ESteamAPIInitResult_OK)
            (*err)[0 .. 4] = "nope";
        return fakeInitResult;
    }

    private extern (C) ESteamAPIInitResult fakeServerInit(uint, ushort, ushort, EServerMode,
            const(char)* ver, const(char)*, SteamErrMsg*) nothrow @nogc
    {
        logCall(fromCString(ver) == "1.2.3.4" ? "server;" : "server(bad version);");
        return fakeInitResult;
    }

    private extern (C) void fakeManualDispatchInit() nothrow @nogc
    {
        logCall("manual;");
    }

    /// Points the init functions at fakes; `uninstallFakes` restores them.
    private void installFakes(ESteamAPIInitResult result)
    {
        callLogLength = 0;
        fakeInitResult = result;
        manualDispatchEnabled = false;
        SteamInternal_SteamAPI_Init = &fakeClientInit;
        SteamInternal_GameServer_Init_V2 = &fakeServerInit;
        SteamAPI_ManualDispatch_Init = &fakeManualDispatchInit;
    }

    private void uninstallFakes()
    {
        SteamInternal_SteamAPI_Init = null;
        SteamInternal_GameServer_Init_V2 = null;
        SteamAPI_ManualDispatch_Init = null;
        manualDispatchEnabled = false;
    }
}

/// Manual dispatch is selected after a successful initialization, as
/// steam_api.h requires, and only once per process.
version (SteamworksDynamic) unittest
{
    import steamworks.loader : isSteamworksLoaded;

    if (isSteamworksLoaded())
        return;
    installFakes(ESteamAPIInitResult.k_ESteamAPIInitResult_OK);
    scope (exit)
        uninstallFakes();
    assert(steamInit());
    assert(lifecycleCalls == "init;manual;", lifecycleCalls);
    assert(steamGameServerInit(0, 1, 2, EServerMode.eServerModeNoAuthentication, "1.2.3.4"));
    assert(lifecycleCalls == "init;manual;server;", lifecycleCalls);
}

/// A failed initialization leaves the dispatch mode alone.
version (SteamworksDynamic) unittest
{
    import steamworks.loader : isSteamworksLoaded;

    if (isSteamworksLoaded())
        return;
    installFakes(ESteamAPIInitResult.k_ESteamAPIInitResult_NoSteamClient);
    scope (exit)
        uninstallFakes();
    const r = steamInit();
    assert(r.result == ESteamAPIInitResult.k_ESteamAPIInitResult_NoSteamClient && r.message == "nope");
    assert(lifecycleCalls == "init;", lifecycleCalls);
}

/// Automatic dispatch never selects manual dispatch.
version (SteamworksDynamic) unittest
{
    import steamworks.loader : isSteamworksLoaded;

    if (isSteamworksLoaded())
        return;
    installFakes(ESteamAPIInitResult.k_ESteamAPIInitResult_OK);
    scope (exit)
        uninstallFakes();
    assert(steamInit(SteamDispatchMode.automatic));
    assert(steamGameServerInit(0, 1, 2, EServerMode.eServerModeNoAuthentication, "1.2.3.4",
            SteamDispatchMode.automatic));
    assert(lifecycleCalls == "init;server;", lifecycleCalls);
}
