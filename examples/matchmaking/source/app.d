/// Lobbies and the server browser.
///
///   matchmaking --host          creates a public lobby tagged with --tag and
///                               prints what happens in it
///   matchmaking                 finds lobbies tagged with --tag, joins the
///                               first one and says hello in its chat
///   matchmaking --servers       lists the app's internet game servers
///   matchmaking --servers --lan lists game servers on the local network
///
/// Lobby searches, creation and joins are call results; chat messages and
/// member changes are callbacks. The server browser reports through a
/// `ServerListResponse`, the delegate-based implementation of the C++
/// `ISteamMatchmakingServerListResponse` interface.
///
/// Run it with Steam running and a steam_appid.txt containing an app ID
/// (480, Spacewar, works for testing) in the working directory; run --host
/// and the default mode under two different Steam accounts to see a lobby
/// from both sides.
module app;

import core.thread : Thread;
import core.time : msecs, MonoTime, seconds;
import std.getopt : defaultGetoptPrinter, getopt;
import std.stdio : stderr, writefln, writeln;
import std.string : toStringz;

import steamworks;

int main(string[] args)
{
    bool host, servers, lan;
    string tag = "steamworks.d-example";
    int duration = 30;
    auto help = getopt(args, "host", "Create a lobby and wait in it", &host, "servers",
            "List game servers instead of lobbies", &servers, "lan",
            "With --servers, search the local network",
            &lan, "tag", "Lobby data value identifying this game's lobbies", &tag, "seconds",
            "How long to run (default 30)", &duration);
    if (help.helpWanted)
    {
        defaultGetoptPrinter("Usage: matchmaking [--host | --servers [--lan]] [options]", help.options);
        return 0;
    }

    if (loadSteamworks() != SteamworksLoadStatus.success)
    {
        stderr.writefln("cannot load %s: %s", steamworksLibraryName, steamworksLoadError());
        return 1;
    }
    const init = steamInit();
    if (!init)
    {
        writefln("Steam is not available: %s (%s)", init.message, init.result);
        return 0;
    }
    scope (exit)
        steamShutdown();

    auto steam = CallbackDispatcher.forClient();
    if (servers)
    {
        auto browser = new ServerBrowser(lan);
        pump(steam, duration, browser.done);
        browser.cancel();
        return 0;
    }

    auto session = new LobbySession(steam, tag);
    scope (exit)
        session.leave();
    if (host)
        session.host();
    else
        session.find();
    pump(steam, duration, session.done);
    return 0;
}

/// One lobby membership: creates or finds a lobby, joins it, and prints its
/// chat and member changes. The methods are the dispatcher's handlers.
final class LobbySession
{
    bool done; /// Set when there is nothing more to wait for.
    private ISteamMatchmaking* mm;
    private CallbackDispatcher* steam;
    private string tag;
    private ulong lobby;

    this(ref CallbackDispatcher steam, string tag)
    {
        this.steam = &steam;
        this.tag = tag;
        mm = SteamMatchmaking();
        steam.register(&onChatMessage);
        steam.register(&onMemberChange);
    }

    /// Creates a public lobby for four members.
    void host()
    {
        steam.call!SteamAPI_ISteamMatchmaking_CreateLobby(mm, k_ELobbyTypePublic, 4).then(&onCreated);
    }

    /// Searches for lobbies carrying this session's tag.
    void find()
    {
        // Filters apply to the next RequestLobbyList call only.
        SteamAPI_ISteamMatchmaking_AddRequestLobbyListStringFilter(mm, "game", tag.toStringz, k_ELobbyComparisonEqual);
        SteamAPI_ISteamMatchmaking_AddRequestLobbyListDistanceFilter(mm, k_ELobbyDistanceFilterWorldwide);
        SteamAPI_ISteamMatchmaking_AddRequestLobbyListResultCountFilter(mm, 20);
        steam.call!SteamAPI_ISteamMatchmaking_RequestLobbyList(mm).then(&onLobbyList);
    }

    /// Leaves the lobby, if in one.
    void leave()
    {
        if (lobby)
            SteamAPI_ISteamMatchmaking_LeaveLobby(mm, lobby);
        lobby = 0;
    }

    private void onCreated(ref const LobbyCreated_t r, bool ioFailure)
    {
        if (ioFailure || r.m_eResult != k_EResultOK)
        {
            done = true;
            return writefln("cannot create a lobby: %s", r.m_eResult);
        }
        // Lobby data is what searches filter on and what members read.
        const name = personaName(SteamAPI_ISteamUser_GetSteamID(SteamUser())) ~ "'s lobby";
        SteamAPI_ISteamMatchmaking_SetLobbyData(mm, r.m_ulSteamIDLobby, "game", tag.toStringz);
        SteamAPI_ISteamMatchmaking_SetLobbyData(mm, r.m_ulSteamIDLobby, "name", name.toStringz);
        entered(r.m_ulSteamIDLobby);
        writeln("waiting for members");
    }

    private void onLobbyList(ref const LobbyMatchList_t r, bool ioFailure)
    {
        if (ioFailure || r.m_nLobbiesMatching == 0)
        {
            done = true;
            return writeln("no lobbies found; start one with --host");
        }
        foreach (i; 0 .. cast(int) r.m_nLobbiesMatching)
        {
            const id = SteamAPI_ISteamMatchmaking_GetLobbyByIndex(mm, i);
            const members = SteamAPI_ISteamMatchmaking_GetNumLobbyMembers(mm, id);
            writefln("lobby %s: %s (%s members)", CSteamID(id).toSteam3String, lobbyName(id), members);
        }
        const first = SteamAPI_ISteamMatchmaking_GetLobbyByIndex(mm, 0);
        steam.call!SteamAPI_ISteamMatchmaking_JoinLobby(mm, first).then(&onEnter);
    }

    private void onEnter(ref const LobbyEnter_t e, bool ioFailure)
    {
        if (ioFailure || e.m_EChatRoomEnterResponse != k_EChatRoomEnterResponseSuccess)
        {
            done = true;
            return writefln("cannot join: response %s", e.m_EChatRoomEnterResponse);
        }
        entered(e.m_ulSteamIDLobby);
        const hello = "hello from steamworks.d";
        // Chat messages are bytes; this one carries its terminating NUL.
        SteamAPI_ISteamMatchmaking_SendLobbyChatMsg(mm, lobby, hello.ptr, cast(int) hello.length + 1);
    }

    private void onChatMessage(ref const LobbyChatMsg_t e)
    {
        char[4096] text;
        CSteamID from;
        EChatEntryType type;
        const n = SteamAPI_ISteamMatchmaking_GetLobbyChatEntry(mm, e.m_ulSteamIDLobby, e.m_iChatID,
                &from, text.ptr, cast(int) text.length, &type);
        if (type == k_EChatEntryTypeChatMsg)
            writefln("%s says: %s", personaName(from.ConvertToUint64()), fromCString(text[0 .. n]));
    }

    private void onMemberChange(ref const LobbyChatUpdate_t e)
    {
        const who = personaName(e.m_ulSteamIDUserChanged);
        if (e.m_rgfChatMemberStateChange & k_EChatMemberStateChangeEntered)
            writefln("%s joined", who);
        else
            writefln("%s left", who);
    }

    private void entered(ulong id)
    {
        lobby = id;
        const count = SteamAPI_ISteamMatchmaking_GetNumLobbyMembers(mm, id);
        writefln("in lobby %s (%s), %s members:", CSteamID(id).toSteam3String, lobbyName(id), count);
        foreach (i; 0 .. count)
            writeln("  ", personaName(SteamAPI_ISteamMatchmaking_GetLobbyMemberByIndex(mm, id, i)));
    }

    private const(char)[] lobbyName(ulong id)
    {
        return fromCString(SteamAPI_ISteamMatchmaking_GetLobbyData(mm, id, "name"));
    }
}

/// Runs the dispatcher until `done` is set or `duration` seconds pass.
void pump(ref CallbackDispatcher steam, int duration, ref bool done)
{
    const deadline = MonoTime.currTime + duration.seconds;
    while (!done && MonoTime.currTime < deadline)
    {
        steam.runFrame();
        Thread.sleep(16.msecs);
    }
}

string personaName(ulong steamID)
{
    return idupCString(SteamAPI_ISteamFriends_GetFriendPersonaName(SteamFriends(), steamID));
}

/// Lists game servers through `ISteamMatchmakingServers`. Steam calls the
/// response object during `runFrame` and holds it until the request is
/// released, so the browser keeps it referenced.
final class ServerBrowser
{
    bool done; /// Set when the list is complete.
    private ISteamMatchmakingServers* servers;
    private ServerListResponse response;
    private HServerListRequest request;

    this(bool lan)
    {
        servers = SteamMatchmakingServers();
        response = new ServerListResponse(&onServer, null, &onRefreshComplete);
        const app = SteamAPI_ISteamUtils_GetAppID(SteamUtils());
        if (lan)
            request = SteamAPI_ISteamMatchmakingServers_RequestLANServerList(servers, app, response);
        else
            request = SteamAPI_ISteamMatchmakingServers_RequestInternetServerList(servers, app, null, 0, response);
    }

    private void onServer(HServerListRequest req, int i) nothrow
    {
        auto s = SteamAPI_ISteamMatchmakingServers_GetServerDetails(servers, req, i);
        const address = fromCString(SteamAPI_servernetadr_t_GetConnectionAddressString(&s.m_NetAdr));
        say("%-40s %-16s %2s/%-2s %4sms %s", fromCString(s.m_szServerName), fromCString(s.m_szMap),
                s.m_nPlayers, s.m_nMaxPlayers, s.m_nPing, address);
    }

    private void onRefreshComplete(HServerListRequest req, EMatchMakingServerResponse r) nothrow
    {
        const count = SteamAPI_ISteamMatchmakingServers_GetServerCount(servers, req);
        say("server list complete: %s (%s servers)", r, count);
        done = true;
    }

    /// Stops the query and releases the request (and with it the response).
    void cancel()
    {
        if (request)
            SteamAPI_ISteamMatchmakingServers_ReleaseRequest(servers, request);
        request = null;
    }
}

/// Prints from the `nothrow` server browser callbacks, which Steam calls from
/// C++ and which therefore must not throw.
void say(Args...)(string fmt, Args args) nothrow
{
    try
        writefln(fmt, args);
    catch (Exception)
    {
    }
}
