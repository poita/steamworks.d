/// Smoke test against the real libsteam_api. Everything it calls works
/// without a running Steam client: the library's own helpers for address
/// and identity structs, callback registration, and the flat wrappers that
/// call back into D implementations of the C++ callback interfaces.
module app;

import core.stdc.string : strlen;
import std.getopt : defaultGetoptPrinter, getopt;
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

private string str(const(char)* s)
{
    return s ? s[0 .. strlen(s)].idup : null;
}

int main(string[] args)
{
    string library;
    auto help = getopt(args, "library",
            "Steamworks library to load (dynamic build; default: next to the executable)", &library);
    if (help.helpWanted)
    {
        defaultGetoptPrinter("Usage: smoke [--library <path>]", help.options);
        return 0;
    }

    version (SteamworksDynamic)
        if (!checkLoader(library))
            return 1;

    checkEveryFunctionResolves();
    checkNoSteamNeeded();
    checkStructHelpers();
    checkCppInterfaces();
    checkCallbackRegistration();

    version (SteamworksDynamic)
    {
        unloadSteamworks();
        check(!isSteamworksLoaded(), "unload");
        size_t nonNull;
        steamworksForEachFunction((string, void* p) nothrow @nogc { nonNull += p !is null; });
        check(nonNull == 0, "pointers reset by unloadSteamworks");
    }

    if (failures)
    {
        stderr.writefln("%s check(s) failed", failures);
        return 1;
    }
    writeln("smoke test passed");
    return 0;
}

/// Loads the library; returns false if the remaining checks cannot run.
version (SteamworksDynamic) private bool checkLoader(string library)
{
    const status = library.length ? loadSteamworks(library) : loadSteamworks();
    if (status != SteamworksLoadStatus.success)
        stderr.writefln("loadSteamworks: %s (%s), %s missing", status, steamworksLoadError(),
                steamworksMissingSymbolCount());
    check(status == SteamworksLoadStatus.success, "loadSteamworks");
    check(isSteamworksLoaded(), "isSteamworksLoaded");
    check(steamworksMissingSymbolCount() == 0, "no missing symbols");
    if (status != SteamworksLoadStatus.success)
        return false;
    check(loadSteamworks() == SteamworksLoadStatus.success, "loading twice keeps the library");
    checkUnboundExports(library);
    return true;
}

/// The exports the bindings deliberately skip really are in the library.
version (SteamworksDynamic) version (Posix) private void checkUnboundExports(string library)
{
    import core.sys.posix.dlfcn : dlclose, dlopen, dlsym, RTLD_LAZY;
    import std.file : thisExePath;
    import std.path : buildPath, dirName;
    import std.string : toStringz;

    const path = library.length ? library : buildPath(thisExePath.dirName, steamworksLibraryName);
    auto h = dlopen(path.toStringz, RTLD_LAZY);
    check(h !is null, "dlopen " ~ path);
    if (!h)
        return;
    foreach (name; steamworksUnboundExports)
        check(dlsym(h, name.toStringz) !is null, "unbound export present: " ~ name);
    dlclose(h);
}

version (SteamworksDynamic) version (Windows) private void checkUnboundExports(string)
{
}

/// Every declared function has an address: bound by the loader, or (linked)
/// referenced here so the linker had to find all of them.
private void checkEveryFunctionResolves()
{
    size_t total, resolved;
    steamworksForEachFunction((string, void* p) nothrow @nogc { ++total; resolved += p !is null; });
    check(total == steamworksFunctionCount, "function count");
    check(resolved == total, "every function resolves");
    writefln("%s of %s functions resolved", resolved, total);
}

private void checkNoSteamNeeded()
{
    const running = SteamAPI_IsSteamRunning();
    writefln("SteamAPI_IsSteamRunning: %s", running);
    writefln("SteamAPI_GetSteamInstallPath: \"%s\"", str(SteamAPI_GetSteamInstallPath()));
    if (running)
        return;
    // Without a client, initialization must fail cleanly and explain why.
    SteamErrMsg msg = 0;
    const r = SteamAPI_InitEx(&msg);
    writefln("SteamAPI_InitEx without Steam: %s \"%s\"", r, str(msg.ptr));
    check(r != ESteamAPIInitResult.k_ESteamAPIInitResult_OK, "init fails without Steam");
    check(msg[0] != 0, "init failure message");
}

private void checkStructHelpers()
{
    servernetadr_t a, b;
    SteamAPI_servernetadr_t_Construct(&a);
    SteamAPI_servernetadr_t_Init(&a, 0x0102_0304, 27_016, 27_015);
    check(SteamAPI_servernetadr_t_GetIP(&a) == 0x0102_0304, "servernetadr_t GetIP");
    check(SteamAPI_servernetadr_t_GetQueryPort(&a) == 27_016, "servernetadr_t GetQueryPort");
    check(SteamAPI_servernetadr_t_GetConnectionPort(&a) == 27_015, "servernetadr_t GetConnectionPort");
    check(str(SteamAPI_servernetadr_t_GetConnectionAddressString(&a)) == "1.2.3.4:27015",
            "servernetadr_t GetConnectionAddressString");
    SteamAPI_servernetadr_t_Assign(&b, a);
    check(b.m_unIP == 0x0102_0304 && b.m_usQueryPort == 27_016, "servernetadr_t Assign");
    SteamAPI_servernetadr_t_SetQueryPort(&b, 27_017);
    check(SteamAPI_servernetadr_t_IsLessThan(&a, b) && !SteamAPI_servernetadr_t_IsLessThan(&b,
            a), "servernetadr_t IsLessThan");
    check(!SteamAPI_servernetadr_t_IsEqualTo(&a, b), "servernetadr_t IsEqualTo (different)");
    SteamAPI_servernetadr_t_SetQueryPort(&b, 27_016);
    check(SteamAPI_servernetadr_t_IsEqualTo(&a, b), "servernetadr_t IsEqualTo");

    gameserveritem_t item;
    item.m_nCurrentFriendCount = 5;
    item.m_nTotalFriendCount = 6;
    SteamAPI_gameserveritem_t_Construct(&item);
    check(item.m_nCurrentFriendCount == 0 && item.m_nTotalFriendCount == 0, "gameserveritem_t friend counts offset");
    SteamAPI_gameserveritem_t_SetName(&item, "D server");
    check(str(SteamAPI_gameserveritem_t_GetName(&item)) == "D server", "gameserveritem_t name");
    check(item.m_szServerName[0 .. 8] == "D server", "gameserveritem_t m_szServerName offset");
    gameserveritem_t other;
    SteamAPI_gameserveritem_t_Construct(&other);
    other.m_NetAdr = item.m_NetAdr;
    other.m_nPing = 99;
    check(SteamAPI_gameserveritem_t_IsEqualTo(&item, other), "gameserveritem_t IsEqualTo compares the address");
    SteamAPI_servernetadr_t_SetConnectionPort(&other.m_NetAdr, 1);
    check(!SteamAPI_gameserveritem_t_IsEqualTo(&item, other), "gameserveritem_t IsEqualTo (different)");

    MatchMakingKeyValuePair_t kv;
    kv.m_szKey[0] = 'x';
    SteamAPI_MatchMakingKeyValuePair_t_Construct(&kv);
    check(kv.m_szKey[0] == 0 && kv.m_szValue[0] == 0, "MatchMakingKeyValuePair_t Construct");

    SteamIPAddress_t ip = SteamIPAddress_t.IPv4Loopback();
    check(SteamAPI_SteamIPAddress_t_IsSet(&ip), "SteamIPAddress_t IsSet");
    ip.m_unIPv4 = 0;
    check(!SteamAPI_SteamIPAddress_t_IsSet(&ip), "SteamIPAddress_t IsSet (unset)");

    SteamNetworkingIPAddr addr;
    SteamAPI_SteamNetworkingIPAddr_SetIPv4(&addr, 0x7f00_0001, 4_242);
    check(SteamAPI_SteamNetworkingIPAddr_IsIPv4(&addr)
            && SteamAPI_SteamNetworkingIPAddr_IsLocalHost(&addr), "SteamNetworkingIPAddr IPv4 localhost");
    check(SteamAPI_SteamNetworkingIPAddr_GetIPv4(&addr) == 0x7f00_0001 && addr.m_port == 4_242,
            "SteamNetworkingIPAddr GetIPv4");
    SteamNetworkingIPAddr addr2;
    addr2.SetIPv4(0x7f00_0001, 4_242);
    check(SteamAPI_SteamNetworkingIPAddr_IsEqualTo(&addr, addr2), "SteamNetworkingIPAddr IsEqualTo");

    SteamNetworkingIdentity id, id2;
    SteamAPI_SteamNetworkingIdentity_SetSteamID64(&id, 76_561_197_960_287_930UL);
    check(SteamAPI_SteamNetworkingIdentity_GetSteamID64(&id) == 76_561_197_960_287_930UL,
            "SteamNetworkingIdentity SteamID64");
    check(id.GetSteamID().GetAccountID() == 22_202, "SteamNetworkingIdentity layout");
    check(SteamAPI_SteamNetworkingIdentity_SetGenericString(&id2, "player"), "SetGenericString");
    check(str(SteamAPI_SteamNetworkingIdentity_GetGenericString(&id2)) == "player", "GetGenericString");
    check(!SteamAPI_SteamNetworkingIdentity_IsEqualTo(&id, id2), "IsEqualTo (different)");
    immutable ubyte[4] bytes = [9, 8, 7, 6];
    check(SteamAPI_SteamNetworkingIdentity_SetGenericBytes(&id2, bytes.ptr, bytes.length), "SetGenericBytes");
    int n;
    const p = SteamAPI_SteamNetworkingIdentity_GetGenericBytes(&id2, n);
    check(n == 4 && p !is null && p[0 .. 4] == bytes, "GetGenericBytes (int& out parameter)");
    id = id2;
    check(SteamAPI_SteamNetworkingIdentity_IsEqualTo(&id, id2), "IsEqualTo (same)");

    SteamNetworkingConfigValue_t cv;
    SteamAPI_SteamNetworkingConfigValue_t_SetInt64(&cv,
            ESteamNetworkingConfigValue.k_ESteamNetworkingConfig_ConnectionUserData, 0x1234_5678_9abc);
    check(cv.m_eDataType == ESteamNetworkingConfigDataType.k_ESteamNetworkingConfig_Int64
            && cv.m_val.m_int64 == 0x1234_5678_9abc, "SteamNetworkingConfigValue_t SetInt64");
    SteamAPI_SteamNetworkingConfigValue_t_SetFloat(&cv,
            ESteamNetworkingConfigValue.k_ESteamNetworkingConfig_FakePacketLoss_Send, 2.5f);
    check(cv.m_val.m_float == 2.5f, "SteamNetworkingConfigValue_t SetFloat");

    SteamDatagramHostedAddress hosted;
    SteamAPI_SteamDatagramHostedAddress_SetDevAddress(&hosted, 0x0a00_0001, 27_020, k_SteamDatagramPOPID_dev);
    check(SteamAPI_SteamDatagramHostedAddress_GetPopID(&hosted) == k_SteamDatagramPOPID_dev,
            "SteamDatagramHostedAddress PopID");
    SteamAPI_SteamDatagramHostedAddress_Clear(&hosted);
    check(hosted.m_cbSize == 0, "SteamDatagramHostedAddress Clear");
}

extern (C++) private class ServerList : ISteamMatchmakingServerListResponse
{
    HServerListRequest request;
    int responded = -1, failed = -1;
    EMatchMakingServerResponse complete = cast(EMatchMakingServerResponse)-1;

    override void ServerResponded(HServerListRequest hRequest, int iServer) nothrow
    {
        request = hRequest;
        responded = iServer;
    }

    override void ServerFailedToRespond(HServerListRequest hRequest, int iServer) nothrow
    {
        failed = iServer;
    }

    override void RefreshComplete(HServerListRequest hRequest, EMatchMakingServerResponse response) nothrow
    {
        complete = response;
    }
}

extern (C++) private class Ping : ISteamMatchmakingPingResponse
{
    int ping = -1;
    bool failed;

    override void ServerResponded(ref gameserveritem_t server) nothrow
    {
        ping = server.m_nPing;
    }

    override void ServerFailedToRespond() nothrow
    {
        failed = true;
    }
}

extern (C++) private class Players : ISteamMatchmakingPlayersResponse
{
    string name;
    int score;
    float time = 0;
    bool done;

    override void AddPlayerToList(const(char)* pchName, int nScore, float flTimePlayed) nothrow
    {
        name = pchName[0 .. strlen(pchName)].idup;
        score = nScore;
        time = flTimePlayed;
    }

    override void PlayersFailedToRespond() nothrow
    {
    }

    override void PlayersRefreshComplete() nothrow
    {
        done = true;
    }
}

extern (C++) private class Rules : ISteamMatchmakingRulesResponse
{
    string rule, value;

    override void RulesResponded(const(char)* pchRule, const(char)* pchValue) nothrow
    {
        rule = pchRule[0 .. strlen(pchRule)].idup;
        value = pchValue[0 .. strlen(pchValue)].idup;
    }

    override void RulesFailedToRespond() nothrow
    {
    }

    override void RulesRefreshComplete() nothrow
    {
    }
}

extern (C++) private class Friends : ISteamMatchmakingServerFriendsResponse
{
    ulong id;
    string name;
    bool connected, failed, done;

    override void AddFriendToList(CSteamID steamID, const(char)* pchName, bool bCurrentlyConnected) nothrow
    {
        id = steamID.ConvertToUint64();
        name = pchName[0 .. strlen(pchName)].idup;
        connected = bCurrentlyConnected;
    }

    override void FriendsFailedToRespond() nothrow
    {
        failed = true;
    }

    override void FriendsRefreshComplete() nothrow
    {
        done = true;
    }
}

/// The library's flat wrappers make C++ virtual calls into D objects.
private void checkCppInterfaces()
{
    auto list = new ServerList;
    auto req = cast(HServerListRequest) cast(void*) 0x1234;
    SteamAPI_ISteamMatchmakingServerListResponse_ServerResponded(list, req, 7);
    SteamAPI_ISteamMatchmakingServerListResponse_ServerFailedToRespond(list, req, 8);
    SteamAPI_ISteamMatchmakingServerListResponse_RefreshComplete(list, req,
            EMatchMakingServerResponse.eNoServersListedOnMasterServer);
    check(list.request == req && list.responded == 7 && list.failed == 8, "ServerListResponse calls");
    check(list.complete == EMatchMakingServerResponse.eNoServersListedOnMasterServer, "RefreshComplete");

    auto ping = new Ping;
    gameserveritem_t item;
    item.m_nPing = 33;
    SteamAPI_ISteamMatchmakingPingResponse_ServerResponded(ping, item);
    SteamAPI_ISteamMatchmakingPingResponse_ServerFailedToRespond(ping);
    check(ping.ping == 33 && ping.failed, "PingResponse calls");

    auto players = new Players;
    SteamAPI_ISteamMatchmakingPlayersResponse_AddPlayerToList(players, "alice", 12, 1.5f);
    SteamAPI_ISteamMatchmakingPlayersResponse_PlayersRefreshComplete(players);
    check(players.name == "alice" && players.score == 12 && players.time == 1.5f && players.done,
            "PlayersResponse calls");

    auto rules = new Rules;
    SteamAPI_ISteamMatchmakingRulesResponse_RulesResponded(rules, "mp_timelimit", "30");
    check(rules.rule == "mp_timelimit" && rules.value == "30", "RulesResponse calls");

    auto friends = new Friends;
    SteamAPI_ISteamMatchmakingServerFriendsResponse_AddFriendToList(friends, 76_561_197_960_287_930UL, "carol", true);
    SteamAPI_ISteamMatchmakingServerFriendsResponse_FriendsFailedToRespond(friends);
    SteamAPI_ISteamMatchmakingServerFriendsResponse_FriendsRefreshComplete(friends);
    check(friends.id == 76_561_197_960_287_930UL && friends.name == "carol" && friends.connected
            && friends.failed && friends.done, "ServerFriendsResponse calls");
}

extern (C++) private class Listener : CCallbackBase
{
    override void Run(void* pvParam) nothrow
    {
    }

    override void Run(void* pvParam, bool bIOFailure, SteamAPICall_t hSteamAPICall) nothrow
    {
    }

    override int GetCallbackSizeBytes() nothrow
    {
        return cast(int) LobbyEnter_t.sizeof;
    }
}

/// SteamAPI_RegisterCallback works before initialization and updates the
/// CCallbackBase fields, which checks their layout against the library.
private void checkCallbackRegistration()
{
    auto l = new Listener;
    SteamAPI_RegisterCallback(l, LobbyEnter_t.k_iCallback);
    check(l.m_iCallback == LobbyEnter_t.k_iCallback, "RegisterCallback sets m_iCallback");
    check((l.m_nCallbackFlags & CCallbackBase.k_ECallbackFlagsRegistered) != 0,
            "RegisterCallback sets the registered flag");
    SteamAPI_UnregisterCallback(l);
    check((l.m_nCallbackFlags & CCallbackBase.k_ECallbackFlagsRegistered) == 0,
            "UnregisterCallback clears the registered flag");
}
