// Calls the ISteamMatchmaking*Response interfaces through the SDK's own C++
// class declarations, the way the Steam client does, so the D classes are
// checked against the compiler's vtable layout and calling convention.
#include <string.h>

#include "steam/steam_api.h"
#include "steam/isteammatchmaking.h"

extern "C" {

void shim_server_list(ISteamMatchmakingServerListResponse *response)
{
    response->ServerResponded(reinterpret_cast<HServerListRequest>(0x1234), 7);
    response->ServerFailedToRespond(reinterpret_cast<HServerListRequest>(0x5678), 8);
    response->RefreshComplete(reinterpret_cast<HServerListRequest>(0x9abc), eNoServersListedOnMasterServer);
}

void shim_ping(ISteamMatchmakingPingResponse *response)
{
    gameserveritem_t item;
    item.m_nPing = 33;
    item.m_nPlayers = 5;
    item.SetName("shim server");
    item.m_steamID = CSteamID(uint64(76561197960287930ULL));
    response->ServerResponded(item);
    response->ServerFailedToRespond();
}

void shim_players(ISteamMatchmakingPlayersResponse *response)
{
    response->AddPlayerToList("alice", 12, 1.5f);
    response->AddPlayerToList("bob", -3, 0.25f);
    response->PlayersFailedToRespond();
    response->PlayersRefreshComplete();
}

void shim_rules(ISteamMatchmakingRulesResponse *response)
{
    response->RulesResponded("mp_timelimit", "30");
    response->RulesFailedToRespond();
    response->RulesRefreshComplete();
}

}
