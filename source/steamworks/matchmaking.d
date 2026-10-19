/// Delegate-based implementations of the C++ callback interfaces that
/// `ISteamMatchmakingServers` reports server browser results through.
///
/// Steam calls these objects through their C++ vtables, so each is an
/// `extern (C++)` class deriving from the raw interface in
/// `steamworks.raw.interfaces`; instead of subclassing, set the delegates for
/// the events of interest (unset ones are ignored):
/// ---
/// auto list = new ServerListResponse;
/// list.onServerResponded = (HServerListRequest req, int i) nothrow {
///     auto server = SteamAPI_ISteamMatchmakingServers_GetServerDetails(SteamMatchmakingServers(), req, i);
///     // ...
/// };
/// list.onRefreshComplete = (HServerListRequest req, EMatchMakingServerResponse) nothrow {
///     SteamAPI_ISteamMatchmakingServers_ReleaseRequest(SteamMatchmakingServers(), req);
/// };
/// auto req = SteamAPI_ISteamMatchmakingServers_RequestInternetServerList(SteamMatchmakingServers(),
///         appID, null, 0, list);
/// ---
///
/// Two rules come from Steam holding a raw pointer to the object:
/// $(UL
///   $(LI Keep a reference to it in D (a field or a global) until the request
///     completes or is cancelled; Steam's copy does not keep it alive for the
///     GC, and a collected object makes the next call crash.)
///   $(LI Delegates are `nothrow`: Steam calls them from C++ code that an
///     exception cannot unwind through.)
/// )
/// Steam invokes them while callbacks are pumped (`runFrame` of a
/// `CallbackDispatcher`, or `SteamAPI_RunCallbacks`).
module steamworks.matchmaking;

import steamworks.raw.enums : EMatchMakingServerResponse;
import steamworks.raw.interfaces : ISteamMatchmakingPingResponse, ISteamMatchmakingPlayersResponse,
    ISteamMatchmakingRulesResponse, ISteamMatchmakingServerListResponse;
import steamworks.raw.structs : gameserveritem_t;
import steamworks.raw.types : HServerListRequest;
import steamworks.strings : fromCString;

// The handler types are declared outside the classes, whose extern (C++)
// scope would otherwise give the delegates C++ linkage.

/// Handler for one server of a server list request.
alias ServerListServerHandler = void delegate(HServerListRequest request, int server) nothrow;
/// Handler for the end of a server list request.
alias ServerListCompleteHandler = void delegate(HServerListRequest request, EMatchMakingServerResponse response) nothrow;
/// Handler for a server's answer to `PingServer`.
alias PingServerHandler = void delegate(ref const gameserveritem_t server) nothrow;
/// Handler for one player reported by `PlayerDetails`.
alias PlayerHandler = void delegate(const(char)[] name, int score, float timePlayed) nothrow;
/// Handler for one rule reported by `ServerRules`.
alias RuleHandler = void delegate(const(char)[] rule, const(char)[] value) nothrow;
/// Handler for an event without data (a failure or a completion).
alias MatchmakingEventHandler = void delegate() nothrow;

/// Receives the results of a server list request
/// (`RequestInternetServerList`, `RequestLANServerList`, ...).
extern (C++) final class ServerListResponse : ISteamMatchmakingServerListResponse
{
    /// Server `server` of `request` answered; read it with `GetServerDetails`.
    ServerListServerHandler onServerResponded;
    /// Server `server` of `request` did not answer.
    ServerListServerHandler onServerFailedToRespond;
    /// The request finished; release it with `ReleaseRequest` when done with
    /// its servers.
    ServerListCompleteHandler onRefreshComplete;

    /// Creates a response with the given handlers (each may be null).
    extern (D) this(typeof(onServerResponded) serverResponded = null,
            typeof(onServerFailedToRespond) serverFailedToRespond = null,
            typeof(onRefreshComplete) refreshComplete = null) nothrow @nogc @safe
    {
        onServerResponded = serverResponded;
        onServerFailedToRespond = serverFailedToRespond;
        onRefreshComplete = refreshComplete;
    }

    /// Forwards to `onServerResponded`.
    override void ServerResponded(HServerListRequest hRequest, int iServer) nothrow
    {
        if (onServerResponded)
            onServerResponded(hRequest, iServer);
    }

    /// Forwards to `onServerFailedToRespond`.
    override void ServerFailedToRespond(HServerListRequest hRequest, int iServer) nothrow
    {
        if (onServerFailedToRespond)
            onServerFailedToRespond(hRequest, iServer);
    }

    /// Forwards to `onRefreshComplete`.
    override void RefreshComplete(HServerListRequest hRequest, EMatchMakingServerResponse response) nothrow
    {
        if (onRefreshComplete)
            onRefreshComplete(hRequest, response);
    }
}

/// Receives the answer to `PingServer`.
extern (C++) final class PingResponse : ISteamMatchmakingPingResponse
{
    /// The server answered with its details.
    PingServerHandler onServerResponded;
    /// The server did not answer.
    MatchmakingEventHandler onServerFailedToRespond;

    /// Creates a response with the given handlers (each may be null).
    extern (D) this(typeof(onServerResponded) serverResponded = null,
            typeof(onServerFailedToRespond) serverFailedToRespond = null) nothrow @nogc @safe
    {
        onServerResponded = serverResponded;
        onServerFailedToRespond = serverFailedToRespond;
    }

    /// Forwards to `onServerResponded`.
    override void ServerResponded(ref gameserveritem_t server) nothrow
    {
        if (onServerResponded)
            onServerResponded(server);
    }

    /// Forwards to `onServerFailedToRespond`.
    override void ServerFailedToRespond() nothrow
    {
        if (onServerFailedToRespond)
            onServerFailedToRespond();
    }
}

/// Receives the player list requested with `PlayerDetails`.
extern (C++) final class PlayersResponse : ISteamMatchmakingPlayersResponse
{
    /// One player: `name` is borrowed from Steam and valid only during the
    /// call; `timePlayed` is in seconds.
    PlayerHandler onAddPlayer;
    /// The server did not answer.
    MatchmakingEventHandler onPlayersFailedToRespond;
    /// Every player has been reported.
    MatchmakingEventHandler onPlayersRefreshComplete;

    /// Creates a response with the given handlers (each may be null).
    extern (D) this(typeof(onAddPlayer) addPlayer = null, typeof(onPlayersFailedToRespond) playersFailedToRespond = null,
            typeof(onPlayersRefreshComplete) playersRefreshComplete = null) nothrow @nogc @safe
    {
        onAddPlayer = addPlayer;
        onPlayersFailedToRespond = playersFailedToRespond;
        onPlayersRefreshComplete = playersRefreshComplete;
    }

    /// Forwards to `onAddPlayer`.
    override void AddPlayerToList(const(char)* pchName, int nScore, float flTimePlayed) nothrow
    {
        if (onAddPlayer)
            onAddPlayer(fromCString(pchName), nScore, flTimePlayed);
    }

    /// Forwards to `onPlayersFailedToRespond`.
    override void PlayersFailedToRespond() nothrow
    {
        if (onPlayersFailedToRespond)
            onPlayersFailedToRespond();
    }

    /// Forwards to `onPlayersRefreshComplete`.
    override void PlayersRefreshComplete() nothrow
    {
        if (onPlayersRefreshComplete)
            onPlayersRefreshComplete();
    }
}

/// Receives the rules requested with `ServerRules`.
extern (C++) final class RulesResponse : ISteamMatchmakingRulesResponse
{
    /// One rule and its value, both borrowed from Steam and valid only during
    /// the call.
    RuleHandler onRule;
    /// The server did not answer.
    MatchmakingEventHandler onRulesFailedToRespond;
    /// Every rule has been reported.
    MatchmakingEventHandler onRulesRefreshComplete;

    /// Creates a response with the given handlers (each may be null).
    extern (D) this(typeof(onRule) rule = null, typeof(onRulesFailedToRespond) rulesFailedToRespond = null,
            typeof(onRulesRefreshComplete) rulesRefreshComplete = null) nothrow @nogc @safe
    {
        onRule = rule;
        onRulesFailedToRespond = rulesFailedToRespond;
        onRulesRefreshComplete = rulesRefreshComplete;
    }

    /// Forwards to `onRule`.
    override void RulesResponded(const(char)* pchRule, const(char)* pchValue) nothrow
    {
        if (onRule)
            onRule(fromCString(pchRule), fromCString(pchValue));
    }

    /// Forwards to `onRulesFailedToRespond`.
    override void RulesFailedToRespond() nothrow
    {
        if (onRulesFailedToRespond)
            onRulesFailedToRespond();
    }

    /// Forwards to `onRulesRefreshComplete`.
    override void RulesRefreshComplete() nothrow
    {
        if (onRulesRefreshComplete)
            onRulesRefreshComplete();
    }
}

/// Calls through the interface types, as Steam does.
unittest
{
    int responded = -1, failed = -1;
    auto complete = EMatchMakingServerResponse.eServerResponded;
    auto list = new ServerListResponse((HServerListRequest, int i) nothrow{ responded = i; });
    list.onServerFailedToRespond = (HServerListRequest, int i) nothrow{ failed = i; };
    list.onRefreshComplete = (HServerListRequest, EMatchMakingServerResponse r) nothrow{
        complete = r;
    };
    ISteamMatchmakingServerListResponse base = list;
    base.ServerResponded(null, 3);
    base.ServerFailedToRespond(null, 4);
    base.RefreshComplete(null, EMatchMakingServerResponse.eNoServersListedOnMasterServer);
    assert(responded == 3 && failed == 4);
    assert(complete == EMatchMakingServerResponse.eNoServersListedOnMasterServer);
}

/// Unset handlers are skipped.
unittest
{
    ISteamMatchmakingServerListResponse list = new ServerListResponse;
    list.ServerResponded(null, 1);
    list.RefreshComplete(null, EMatchMakingServerResponse.eServerResponded);
    ISteamMatchmakingPingResponse ping = new PingResponse;
    gameserveritem_t item;
    ping.ServerResponded(item);
    ping.ServerFailedToRespond();
    ISteamMatchmakingPlayersResponse players = new PlayersResponse;
    players.AddPlayerToList("x", 1, 1);
    players.PlayersRefreshComplete();
    ISteamMatchmakingRulesResponse rules = new RulesResponse;
    rules.RulesResponded("a", "b");
    rules.RulesFailedToRespond();
}

unittest
{
    int ping;
    bool failed;
    ISteamMatchmakingPingResponse response = new PingResponse((ref const gameserveritem_t s) nothrow{
        ping = s.m_nPing;
    }, () nothrow{ failed = true; });
    gameserveritem_t item;
    item.m_nPing = 42;
    response.ServerResponded(item);
    response.ServerFailedToRespond();
    assert(ping == 42 && failed);
}

unittest
{
    string name;
    int score;
    float time = 0;
    bool done;
    ISteamMatchmakingPlayersResponse response = new PlayersResponse((const(char)[] n, int s, float t) nothrow{
        name = n.idup;
        score = s;
        time = t;
    }, null, () nothrow{ done = true; });
    response.AddPlayerToList("alice", 12, 1.5f);
    response.PlayersFailedToRespond();
    response.PlayersRefreshComplete();
    assert(name == "alice" && score == 12 && time == 1.5f && done);
}

unittest
{
    string[] seen;
    bool done;
    auto response = new RulesResponse;
    response.onRule = (const(char)[] rule, const(char)[] value) nothrow{
        seen ~= (rule ~ "=" ~ value).idup;
    };
    response.onRulesRefreshComplete = () nothrow{ done = true; };
    ISteamMatchmakingRulesResponse base = response;
    base.RulesResponded("mp_timelimit", "30");
    base.RulesResponded("empty", null);
    base.RulesRefreshComplete();
    assert(seen == ["mp_timelimit=30", "empty="] && done);
}
