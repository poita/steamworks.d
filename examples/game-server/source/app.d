/// A dedicated game server: initializes the game server API, logs on
/// anonymously, advertises itself to the server browser and reports its
/// connection to Steam until stopped.
///
/// Game servers use their own pipe, so the dispatcher comes from
/// `CallbackDispatcher.forGameServer()` and the interfaces from the
/// `SteamGameServer*()` accessors. Players joining would send an auth ticket
/// (`ISteamUser::GetAuthTicketForWebApi` / `GetAuthSessionTicket` on the
/// client) for `BeginAuthSession`; Steam answers with
/// `ValidateAuthTicketResponse_t`, which is handled here.
///
/// A game server needs no running Steam client, but it does need
/// steamclient (shipped with Steam and with SteamCMD) and a steam_appid.txt
/// containing the app ID in the working directory. The game's own app ID
/// must allow anonymous game server logins; Spacewar (480) does. Find it in
/// the matchmaking example with `matchmaking --servers --lan`.
module app;

import core.thread : Thread;
import core.time : msecs, MonoTime, seconds;
import std.getopt : defaultGetoptPrinter, getopt;
import std.stdio : stderr, writefln, writeln;
import std.string : toStringz;

import steamworks;

int main(string[] args)
{
    ushort gamePort = 27_015;
    ushort queryPort = 27_016;
    string name = "steamworks.d example server";
    string product = "SteamworksExample";
    string map = "e1m1";
    int maxPlayers = 8;
    int duration = 60;
    auto help = getopt(args, "port", "Game port (default 27015)", &gamePort, "query-port",
            "Server browser query port (default 27016)", &queryPort,
            "name", "Server name shown in the browser",
            &name, "product", "Product and mod directory name", &product, "map",
            "Map name shown in the browser", &map, "max-players",
            "Player slots (default 8)", &maxPlayers, "seconds", "How long to run (default 60)", &duration);
    if (help.helpWanted)
    {
        defaultGetoptPrinter("Usage: game-server [options]", help.options);
        return 0;
    }

    if (loadSteamworks() != SteamworksLoadStatus.success)
    {
        stderr.writefln("cannot load %s: %s", steamworksLibraryName, steamworksLoadError());
        return 1;
    }
    const init = steamGameServerInit(0, gamePort, queryPort, eServerModeAuthenticationAndSecure, "1.0.0.0");
    if (!init)
    {
        writefln("cannot start the game server: %s (%s)", init.message, init.result);
        return 0;
    }
    scope (exit)
        steamGameServerShutdown();

    auto server = SteamGameServer();
    // These describe the server to Steam and must be set before logging on.
    SteamAPI_ISteamGameServer_SetProduct(server, product.toStringz);
    SteamAPI_ISteamGameServer_SetModDir(server, product.toStringz);
    SteamAPI_ISteamGameServer_SetGameDescription(server, "steamworks.d example");
    SteamAPI_ISteamGameServer_SetDedicatedServer(server, true);

    auto steam = CallbackDispatcher.forGameServer();
    bool stop;
    steam.register!SteamServersConnected_t((ref const _) {
        writefln("logged on as %s", CSteamID(SteamAPI_ISteamGameServer_GetSteamID(server)).toSteam3String);
        const ip = SteamAPI_ISteamGameServer_GetPublicIP(server);
        if (ip.IsSet() && ip.m_eType == k_ESteamIPTypeIPv4)
            writefln("public address %s.%s.%s.%s:%s", ip.m_unIPv4 >> 24, (ip.m_unIPv4 >> 16) & 0xff,
                (ip.m_unIPv4 >> 8) & 0xff, ip.m_unIPv4 & 0xff, gamePort);
    });
    steam.register((ref const SteamServerConnectFailure_t e) {
        writefln("cannot log on: %s%s", e.m_eResult, e.m_bStillRetrying ? " (retrying)" : "");
        stop = !e.m_bStillRetrying;
    });
    steam.register((ref const SteamServersDisconnected_t e) {
        writefln("lost the connection to Steam: %s", e.m_eResult);
    });
    steam.register((ref const GSPolicyResponse_t e) {
        writefln("VAC %s", e.m_bSecure ? "secured" : "not secured");
    });
    steam.register((ref const ValidateAuthTicketResponse_t e) {
        writefln("auth ticket of %s: %s", e.m_SteamID.toSteam3String, e.m_eAuthSessionResponse);
        if (e.m_eAuthSessionResponse != k_EAuthSessionResponseOK)
            SteamAPI_ISteamGameServer_EndAuthSession(server, e.m_SteamID.ConvertToUint64());
    });

    SteamAPI_ISteamGameServer_LogOnAnonymous(server);
    scope (exit)
        SteamAPI_ISteamGameServer_LogOff(server);

    // The rules and player counts the server browser shows; update them as
    // the game changes.
    SteamAPI_ISteamGameServer_SetServerName(server, name.toStringz);
    SteamAPI_ISteamGameServer_SetMapName(server, map.toStringz);
    SteamAPI_ISteamGameServer_SetMaxPlayerCount(server, maxPlayers);
    SteamAPI_ISteamGameServer_SetBotPlayerCount(server, 0);
    SteamAPI_ISteamGameServer_SetGameTags(server, "example,steamworks.d");
    SteamAPI_ISteamGameServer_SetAdvertiseServerActive(server, true);

    const deadline = MonoTime.currTime + duration.seconds;
    while (!stop && MonoTime.currTime < deadline)
    {
        steam.runFrame();
        Thread.sleep(50.msecs);
    }
    SteamAPI_ISteamGameServer_SetAdvertiseServerActive(server, false);
    writeln("shutting down");
    return 0;
}
