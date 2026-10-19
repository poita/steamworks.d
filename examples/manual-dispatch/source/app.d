/// Initializes the Steam API and pumps callbacks with manual dispatch.
///
/// Run it with Steam running and a steam_appid.txt containing an app ID
/// (480, Spacewar, works for testing) in the working directory. Without
/// Steam it reports why initialization failed and exits.
module app;

import core.stdc.string : strlen;
import core.thread : Thread;
import core.time : msecs;
import std.getopt : defaultGetoptPrinter, getopt;
import std.stdio : stderr, writefln, writeln;

import steamworks;

int main(string[] args)
{
    int frames = 60;
    auto help = getopt(args, "frames", "Frames of callbacks to pump (default 60)", &frames);
    if (help.helpWanted)
    {
        defaultGetoptPrinter("Usage: manual-dispatch [--frames N]", help.options);
        return 0;
    }

    const status = loadSteamworks();
    if (status != SteamworksLoadStatus.success)
    {
        stderr.writefln("cannot load %s: %s %s", steamworksLibraryName, status, steamworksLoadError());
        return 1;
    }

    // Manual dispatch must be selected before initialization.
    SteamAPI_ManualDispatch_Init();
    SteamErrMsg err = 0;
    if (SteamAPI_InitEx(&err) != ESteamAPIInitResult.k_ESteamAPIInitResult_OK)
    {
        writefln("Steam is not available: %s", err.ptr[0 .. strlen(err.ptr)]);
        return 0;
    }
    scope (exit)
        SteamAPI_Shutdown();

    auto user = SteamAPI_SteamUser();
    auto friends = SteamAPI_SteamFriends();
    const id = CSteamID(SteamAPI_ISteamUser_GetSteamID(user));
    const name = SteamAPI_ISteamFriends_GetPersonaName(friends);
    writefln("logged in as %s (account %s)", name[0 .. strlen(name)], id.GetAccountID());

    // An asynchronous call: its result arrives as a SteamAPICallCompleted_t.
    const call = SteamAPI_ISteamUserStats_RequestGlobalAchievementPercentages(SteamAPI_SteamUserStats());

    const pipe = SteamAPI_GetHSteamPipe();
    foreach (_; 0 .. frames)
    {
        SteamAPI_ManualDispatch_RunFrame(pipe);
        CallbackMsg_t msg;
        while (SteamAPI_ManualDispatch_GetNextCallback(pipe, &msg))
        {
            scope (exit)
                SteamAPI_ManualDispatch_FreeLastCallback(pipe);
            if (msg.m_iCallback == SteamAPICallCompleted_t.k_iCallback)
            {
                auto done = cast(SteamAPICallCompleted_t*) msg.m_pubParam;
                if (done.m_hAsyncCall != call)
                    continue;
                GlobalAchievementPercentagesReady_t result;
                bool failed;
                if (SteamAPI_ManualDispatch_GetAPICallResult(pipe, call, &result, result.sizeof,
                        GlobalAchievementPercentagesReady_t.k_iCallback, &failed) && !failed)
                    writefln("achievement percentages: %s", result.m_eResult);
            }
            else if (msg.m_iCallback == PersonaStateChange_t.k_iCallback)
            {
                auto change = cast(PersonaStateChange_t*) msg.m_pubParam;
                writefln("persona state change for %s", change.m_ulSteamID);
            }
        }
        Thread.sleep(16.msecs);
    }
    writeln("done");
    return 0;
}
