/// Calls D implementations of the ISteamMatchmaking*Response interfaces from
/// clang-compiled C++ (shim.cpp), covering both the delegate-based classes of
/// steamworks.matchmaking and a direct subclass of the raw interface.
module main;

import core.stdc.stdio : printf;
import steamworks.matchmaking;
import steamworks.raw.enums : EMatchMakingServerResponse;
import steamworks.raw.interfaces;
import steamworks.raw.structs : gameserveritem_t;
import steamworks.raw.types : HServerListRequest;
import steamworks.raw.steamid : CSteamID;
import steamworks.steamid : accountID;
import steamworks.strings : fromCString;

extern (C) nothrow
{
    void shim_server_list(ISteamMatchmakingServerListResponse response);
    void shim_ping(ISteamMatchmakingPingResponse response);
    void shim_players(ISteamMatchmakingPlayersResponse response);
    void shim_rules(ISteamMatchmakingRulesResponse response);
    void shim_friends(ISteamMatchmakingServerFriendsResponse response);
}

private int failures;

private void check(bool ok, const(char)* what)
{
    printf("%s  %s\n", ok ? "ok  ".ptr : "FAIL".ptr, what);
    if (!ok)
        ++failures;
}

/// A direct subclass of the raw interface, as an application may write it.
extern (C++) final class RawList : ISteamMatchmakingServerListResponse
{
    size_t[3] requests;
    int responded = -1, failed = -1;
    EMatchMakingServerResponse complete;

    override void ServerResponded(HServerListRequest hRequest, int iServer) nothrow
    {
        requests[0] = cast(size_t) hRequest;
        responded = iServer;
    }

    override void ServerFailedToRespond(HServerListRequest hRequest, int iServer) nothrow
    {
        requests[1] = cast(size_t) hRequest;
        failed = iServer;
    }

    override void RefreshComplete(HServerListRequest hRequest, EMatchMakingServerResponse response) nothrow
    {
        requests[2] = cast(size_t) hRequest;
        complete = response;
    }
}

int main()
{
    {
        auto raw = new RawList;
        shim_server_list(raw);
        check(raw.requests == [0x1234, 0x5678, 0x9abc] && raw.responded == 7 && raw.failed == 8
                && raw.complete == EMatchMakingServerResponse.eNoServersListedOnMasterServer,
                "raw ISteamMatchmakingServerListResponse subclass");
    }
    {
        size_t[3] requests;
        int responded = -1, failed = -1;
        EMatchMakingServerResponse complete;
        auto list = new ServerListResponse((HServerListRequest r, int i) nothrow{
            requests[0] = cast(size_t) r;
            responded = i;
        }, (HServerListRequest r, int i) nothrow{ requests[1] = cast(size_t) r; failed = i; },
                (HServerListRequest r, EMatchMakingServerResponse c) nothrow{
            requests[2] = cast(size_t) r;
            complete = c;
        });
        shim_server_list(list);
        check(requests == [0x1234, 0x5678, 0x9abc] && responded == 7 && failed == 8
                && complete == EMatchMakingServerResponse.eNoServersListedOnMasterServer, "ServerListResponse");
    }
    {
        int ping, players, friendsNow, friendsEver;
        uint account;
        const(char)[] name;
        bool failed;
        auto response = new PingResponse((ref const gameserveritem_t s) nothrow{
            ping = s.m_nPing;
            players = s.m_nPlayers;
            name = fromCString(s.m_szServerName).dup;
            account = s.m_steamID.accountID;
            friendsNow = s.m_nCurrentFriendCount;
            friendsEver = s.m_nTotalFriendCount;
        }, () nothrow{ failed = true; });
        shim_ping(response);
        check(ping == 33 && players == 5 && name == "shim server" && account == 22_202 && failed, "PingResponse");
        check(friendsNow == 2 && friendsEver == 9, "gameserveritem_t friend counts");
    }
    {
        string log;
        int calls;
        auto response = new PlayersResponse((const(char)[] n, int score, float time) nothrow{
            if ((n == "alice" && score == 12 && time == 1.5f) || (n == "bob" && score == -3 && time == 0.25f))
                ++calls;
        }, () nothrow{ log ~= "failed;"; }, () nothrow{ log ~= "complete;"; });
        shim_players(response);
        check(calls == 2 && log == "failed;complete;", "PlayersResponse");
    }
    {
        string log;
        auto response = new RulesResponse((const(char)[] rule, const(char)[] value) nothrow{
            log ~= rule ~ "=" ~ value ~ ";";
        }, () nothrow{ log ~= "failed;"; }, () nothrow{ log ~= "complete;"; });
        shim_rules(response);
        check(log == "mp_timelimit=30;failed;complete;", "RulesResponse");
    }
    {
        string log;
        auto response = new ServerFriendsResponse((CSteamID id, const(char)[] name, bool now) nothrow{
            log ~= name ~ (now ? "+" : "-") ~ (id.accountID == 22_202 || id.accountID == 22_203 ? ";" : "?;");
        }, () nothrow{ log ~= "failed;"; }, () nothrow{ log ~= "complete;"; });
        shim_friends(response);
        check(log == "carol+;dave-;failed;complete;", "ServerFriendsResponse");
    }
    return failures ? 1 : 0;
}
