/// Initializes the Steam API and handles callbacks and call results with a
/// `CallbackDispatcher`.
///
/// Run it with Steam running and a steam_appid.txt containing an app ID
/// (480, Spacewar, works for testing) in the working directory. Without
/// Steam it reports why initialization failed and exits.
module app;

import core.thread : Thread;
import core.time : msecs;
import std.getopt : defaultGetoptPrinter, getopt;
import std.stdio : stderr, writefln, writeln;

import steamworks;

int main(string[] args)
{
    int frames = 120;
    auto help = getopt(args, "frames", "Frames of callbacks to pump (default 120)", &frames);
    if (help.helpWanted)
    {
        defaultGetoptPrinter("Usage: dispatcher [--frames N]", help.options);
        return 0;
    }

    const status = loadSteamworks();
    if (status != SteamworksLoadStatus.success)
    {
        stderr.writefln("cannot load %s: %s %s", steamworksLibraryName, status, steamworksLoadError());
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

    const me = CSteamID(SteamAPI_ISteamUser_GetSteamID(SteamUser()));
    writefln("logged in as %s %s",
            fromCString(SteamAPI_ISteamFriends_GetPersonaName(SteamFriends())), me.toSteam3String);

    auto steam = CallbackDispatcher.forClient();

    // A callback: every PersonaStateChange_t until unregistered.
    auto personaToken = steam.register((ref const PersonaStateChange_t e) {
        writefln("persona state change for %s (flags %#x)", CSteamID(e.m_ulSteamID).toSteam3String, e.m_nChangeFlags);
    });

    // A call result, with the struct type taken from the function's attribute.
    steam.call!SteamAPI_ISteamUserStats_GetNumberOfCurrentPlayers(SteamUserStats()).then((ref r, ioFailure) {
        if (ioFailure || !r.m_bSuccess)
            writeln("player count unavailable");
        else
            writefln("%s players in game", r.m_cPlayers);
    });

    // A call result named explicitly.
    const find = SteamAPI_ISteamUserStats_FindLeaderboard(SteamUserStats(), "Feet Traveled");
    steam.callResult!LeaderboardFindResult_t(find, (ref r, ioFailure) {
        writefln("leaderboard %s", !ioFailure && r.m_bLeaderboardFound ? "found" : "not found");
    });

    foreach (_; 0 .. frames)
    {
        steam.runFrame();
        Thread.sleep(16.msecs);
    }
    steam.unregister(personaToken);
    writeln("done");
    return 0;
}
