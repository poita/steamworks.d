/// Stats, achievements and leaderboards: lists the app's achievements with
/// their global unlock percentages, optionally unlocks or clears one and
/// changes an integer stat, stores the result, and uploads a score to a
/// leaderboard before printing the entries around the user.
///
/// Every asynchronous step goes through the dispatcher: callbacks for
/// `UserStatsReceived_t`, `UserStatsStored_t` and `UserAchievementStored_t`,
/// call results for the global percentages and the leaderboard calls.
///
/// Run it with Steam running and a steam_appid.txt containing an app ID in
/// the working directory. Spacewar (480) defines achievements such as
/// ACH_WIN_ONE_GAME, the stat NumGames and the leaderboard "Feet Traveled":
///
///   achievements --unlock ACH_WIN_ONE_GAME --stat NumGames --add 1 \
///       --leaderboard "Feet Traveled" --score 1234
module app;

import core.thread : Thread;
import core.time : msecs, MonoTime, seconds;
import std.datetime.systime : SysTime;
import std.getopt : defaultGetoptPrinter, getopt;
import std.stdio : stderr, writefln, writeln;
import std.string : toStringz;

import steamworks;

int main(string[] args)
{
    string unlock, clear, stat, leaderboard;
    int add, score;
    int timeout = 10;
    auto help = getopt(args, "unlock", "Unlock this achievement (API name)", &unlock, "clear",
            "Clear this achievement (API name; for testing)",
            &clear, "stat", "Integer stat to change", &stat, "add", "Amount added to --stat",
            &add, "leaderboard", "Leaderboard to find (or create) and show",
            &leaderboard, "score", "Score uploaded to --leaderboard (kept if better)",
            &score, "timeout", "Seconds to wait for Steam (default 10)", &timeout);
    if (help.helpWanted)
    {
        defaultGetoptPrinter("Usage: achievements [options]", help.options);
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

    auto stats = SteamUserStats();
    auto steam = CallbackDispatcher.forClient();
    const me = SteamAPI_ISteamUser_GetSteamID(SteamUser());
    int pending; // asynchronous steps still outstanding

    // Steam fetches the local user's stats during initialization and posts
    // UserStatsReceived_t when they arrive; until then the getters fail.
    steam.register((ref const UserStatsReceived_t e) {
        if (e.m_steamIDUser.ConvertToUint64() == me)
            writefln("stats received: %s", e.m_eResult);
    });
    steam.register((ref const UserStatsStored_t e) {
        --pending;
        writefln("stats stored: %s", e.m_eResult);
    });
    steam.register((ref const UserAchievementStored_t e) {
        writefln("achievement %s stored", fromCString(e.m_rgchAchievementName));
    });

    // Global unlock percentages for every achievement of the app.
    ++pending;
    steam.call!SteamAPI_ISteamUserStats_RequestGlobalAchievementPercentages(stats)
        .then((ref const GlobalAchievementPercentagesReady_t r, bool ioFailure) {
            --pending;
            if (ioFailure || r.m_eResult != k_EResultOK)
                return writeln("global achievement percentages unavailable");
            printPercentages(stats);
        });

    if (leaderboard.length)
    {
        ++pending;
        auto board = new LeaderboardTask(steam, leaderboard, score, () { --pending; });
        board.start();
    }

    bool listed;
    const deadline = MonoTime.currTime + timeout.seconds;
    while (MonoTime.currTime < deadline && (!listed || pending > 0))
    {
        steam.runFrame();
        if (!listed && listAchievements(stats))
        {
            listed = true;
            if (applyChanges(stats, unlock, clear, stat, add))
            {
                // Uploads the changes; Steam answers with UserStatsStored_t.
                if (SteamAPI_ISteamUserStats_StoreStats(stats))
                    ++pending;
            }
        }
        Thread.sleep(16.msecs);
    }
    if (!listed)
        writeln("stats did not arrive in time");
    return 0;
}

/// Finds (or creates) a leaderboard, optionally uploads a score, then
/// downloads the entries around the user: three call results in sequence,
/// each started from the previous one's handler.
final class LeaderboardTask
{
    private CallbackDispatcher* steam;
    private ISteamUserStats* stats;
    private string name;
    private int score;
    private void delegate() finished;
    private SteamLeaderboard_t board;

    this(ref CallbackDispatcher steam, string name, int score, void delegate() finished)
    {
        this.steam = &steam;
        this.name = name;
        this.score = score;
        this.finished = finished;
        stats = SteamUserStats();
    }

    void start()
    {
        const call = SteamAPI_ISteamUserStats_FindOrCreateLeaderboard(stats, name.toStringz,
                k_ELeaderboardSortMethodDescending, k_ELeaderboardDisplayTypeNumeric);
        steam.callResult!LeaderboardFindResult_t(call, &onFound);
    }

    private void onFound(ref const LeaderboardFindResult_t r, bool ioFailure)
    {
        if (ioFailure || !r.m_bLeaderboardFound)
        {
            writefln("leaderboard %s not found", name);
            return finished();
        }
        board = r.m_hSteamLeaderboard;
        const entries = SteamAPI_ISteamUserStats_GetLeaderboardEntryCount(stats, board);
        writefln("leaderboard %s has %s entries", name, entries);
        if (score == 0)
            return download();
        steam.call!SteamAPI_ISteamUserStats_UploadLeaderboardScore(stats, board,
                k_ELeaderboardUploadScoreMethodKeepBest, score, null, 0).then(&onUploaded);
    }

    private void onUploaded(ref const LeaderboardScoreUploaded_t r, bool ioFailure)
    {
        if (ioFailure || !r.m_bSuccess)
            writeln("score upload failed");
        else
            writefln("score %s uploaded (%s), global rank %s", r.m_nScore, r.m_bScoreChanged
                    ? "new best" : "not better", r.m_nGlobalRankNew);
        download();
    }

    private void download()
    {
        steam.call!SteamAPI_ISteamUserStats_DownloadLeaderboardEntries(stats, board,
                k_ELeaderboardDataRequestGlobalAroundUser, -3, 3).then(&onDownloaded);
    }

    private void onDownloaded(ref const LeaderboardScoresDownloaded_t r, bool ioFailure)
    {
        scope (exit)
            finished();
        if (ioFailure)
            return writeln("leaderboard download failed");
        foreach (i; 0 .. r.m_cEntryCount)
        {
            LeaderboardEntry_t e;
            if (SteamAPI_ISteamUserStats_GetDownloadedLeaderboardEntry(stats,
                    r.m_hSteamLeaderboardEntries, i, &e, null, 0))
                writefln("  #%-6s %-22s %s", e.m_nGlobalRank, e.m_steamIDUser.toSteam3String, e.m_nScore);
        }
    }
}

/// Prints the share of players who unlocked each achievement.
void printPercentages(ISteamUserStats* stats)
{
    foreach (i; 0 .. SteamAPI_ISteamUserStats_GetNumAchievements(stats))
    {
        auto name = SteamAPI_ISteamUserStats_GetAchievementName(stats, i);
        float percent;
        if (SteamAPI_ISteamUserStats_GetAchievementAchievedPercent(stats, name, &percent))
            writefln("  %-32s %5.1f%% of players", fromCString(name), percent);
    }
}

/// Prints every achievement, or returns false while the stats are not yet
/// available.
bool listAchievements(ISteamUserStats* stats)
{
    const count = SteamAPI_ISteamUserStats_GetNumAchievements(stats);
    if (count == 0)
        return false;
    foreach (i; 0 .. count)
    {
        auto name = SteamAPI_ISteamUserStats_GetAchievementName(stats, i);
        bool achieved;
        uint unlockTime;
        if (!SteamAPI_ISteamUserStats_GetAchievementAndUnlockTime(stats, name, &achieved, &unlockTime))
            return false;
        const title = fromCString(SteamAPI_ISteamUserStats_GetAchievementDisplayAttribute(stats, name, "name"));
        if (achieved)
            writefln("[x] %-32s %s (unlocked %s)", fromCString(name), title,
                    SysTime.fromUnixTime(unlockTime).toSimpleString);
        else
            writefln("[ ] %-32s %s", fromCString(name), title);
    }
    return true;
}

/// Applies the requested achievement and stat changes; returns whether
/// anything changed and needs storing.
bool applyChanges(ISteamUserStats* stats, string unlock, string clear, string stat, int add)
{
    bool changed;
    if (unlock.length)
        changed |= report(SteamAPI_ISteamUserStats_SetAchievement(stats, unlock.toStringz), "unlock", unlock);
    if (clear.length)
        changed |= report(SteamAPI_ISteamUserStats_ClearAchievement(stats, clear.toStringz), "clear", clear);
    if (stat.length)
    {
        int value;
        if (SteamAPI_ISteamUserStats_GetStatInt32(stats, stat.toStringz, &value))
        {
            changed |= report(SteamAPI_ISteamUserStats_SetStatInt32(stats, stat.toStringz, value + add), "set", stat);
            writefln("%s: %s -> %s", stat, value, value + add);
        }
        else
            writefln("no integer stat %s", stat);
    }
    return changed;
}

bool report(bool ok, string what, string name)
{
    if (!ok)
        writefln("cannot %s %s", what, name);
    return ok;
}
