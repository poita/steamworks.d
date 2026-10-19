/// Runs the D layer (steamworks.lifecycle, accessors, dispatch, networking)
/// against the real libsteam_api with no Steam client running: everything
/// here must fail cleanly, with no crash and no call into a missing interface.
module app;

import std.stdio : stderr, writefln, writeln;

import steamworks;

private int failures;

private void check(bool ok, string what, string file = __FILE__, size_t line = __LINE__)
{
    if (ok)
        return;
    ++failures;
    stderr.writefln("FAILED %s:%s: %s", file, line, what);
}

int main()
{
    version (SteamworksDynamic)
    {
        // Initialization without the library reports why instead of crashing.
        const early = steamInit();
        check(!early && early.message.length > 0, "steamInit before loadSteamworks");
        const status = loadSteamworks();
        if (status != SteamworksLoadStatus.success)
        {
            stderr.writefln("cannot load %s: %s %s", steamworksLibraryName, status, steamworksLoadError());
            return 1;
        }
    }

    checkInitWithoutSteam();
    checkDispatcherWithoutSteam();
    checkNetworkingText();

    if (failures)
    {
        stderr.writefln("%s check(s) failed", failures);
        return 1;
    }
    writeln("layer test passed");
    return 0;
}

void checkInitWithoutSteam()
{
    check(!SteamAPI_IsSteamRunning(), "no Steam client is running");
    const r = steamInit();
    check(!r.ok, "steamInit fails without Steam");
    check(r.message.length > 0, "steamInit explains the failure");
    writefln("steamInit without Steam: %s \"%s\"", r.result, r.message);

    bool threw;
    try
        steamInitOrThrow();
    catch (SteamInitException e)
    {
        threw = e.result != ESteamAPIInitResult.k_ESteamAPIInitResult_OK && e.msg.length > 0;
    }
    check(threw, "steamInitOrThrow throws SteamInitException");

    check(SteamUser() is null && SteamFriends() is null, "client accessors are null before initialization");
    check(SteamGameServer() is null, "game server accessor is null before initialization");
    steamShutdown();
}

void checkDispatcherWithoutSteam()
{
    auto d = CallbackDispatcher.forClient();
    check(d.pipe == 0, "no client pipe without Steam");
    bool called;
    d.register((ref const PersonaStateChange_t e) { called = true; });
    d.runFrame(); // pipe 0: does nothing
    check(!called, "idle dispatcher delivers nothing");
    auto server = NogcCallbackDispatcher.forGameServer();
    check(server.pipe == 0, "no game server pipe without a game server");
}

void checkNetworkingText()
{
    // Steam's networking utilities only exist once Steam is initialized;
    // without them the conversions do nothing rather than crash.
    SteamNetworkingIPAddr addr;
    addr.SetIPv4(0xC0A8_0001, 27_015);
    char[64] buffer = 'x';
    check(formatIPAddr(addr, buffer[]).length == 0, "no address text without Steam");
    check(ipAddrToString(addr) is null, "no address string without Steam");
    check(!parseIPAddr("192.168.0.1:27015", addr) && addr.IsIPv6AllZeros(), "no address parsing without Steam");

    SteamNetworkingIdentity id;
    id.SetSteamID64(76_561_197_960_287_930UL);
    check(formatIdentity(id, buffer[]).length == 0, "no identity text without Steam");
    check(!parseIdentity("steamid:76561197960287930", id) && id.IsInvalid(), "no identity parsing without Steam");
}
