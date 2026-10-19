/// User-defined attributes the generator attaches to flat API functions.
///
/// They carry metadata from steam_api.json that C cannot express, so that
/// higher-level code can, for instance, pair an asynchronous call with the
/// struct it completes with:
/// ---
/// import std.traits : getUDAs;
/// alias R = getUDAs!(SteamAPI_ISteamUserStats_FindLeaderboard, SteamCallResult)[0].Result;
/// static assert(is(R == LeaderboardFindResult_t));
/// ---
module steamworks.raw.attributes;

/// The function returns a `SteamAPICall_t` that completes with a `T`
/// (delivered through `SteamAPICallCompleted_t` or a registered call result).
struct SteamCallResult(T)
{
    /// The call-result struct.
    alias Result = T;
}

/// The function's outcome is posted as callback `T`.
struct SteamCallback(T)
{
    /// The callback struct.
    alias Callback = T;
}
