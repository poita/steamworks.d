/// The interface accessors under their C++ names: `SteamUser()`,
/// `SteamFriends()`, `SteamGameServer()` and so on.
///
/// Each returns the interface pointer for the version these bindings were
/// generated for (through the library's versioned accessor, such as
/// `SteamAPI_SteamUser_v023`), or null before the matching initialization
/// (`steamInit` for the client accessors, `steamGameServerInit` for the
/// `SteamGameServer*` ones). Pass the pointer as `self` to the flat functions:
/// ---
/// const name = SteamAPI_ISteamFriends_GetPersonaName(SteamFriends());
/// ---
/// With the "dynamic" configuration they also return null while the library
/// is not loaded or when it lacks the versioned accessor.
/// `SteamClient()` and `SteamGameServerClient()` live in `steamworks.raw.helpers`.
module steamworks.accessors;

import steamworks.raw;

/// Returns the `ISteamApps` interface (`SteamAPI_SteamApps`).
ISteamApps* SteamApps() nothrow @nogc
{
    return SteamAPI_SteamApps();
}

/// Returns the `ISteamController` interface (`SteamAPI_SteamController`).
ISteamController* SteamController() nothrow @nogc
{
    return SteamAPI_SteamController();
}

/// Returns the `ISteamFriends` interface (`SteamAPI_SteamFriends`).
ISteamFriends* SteamFriends() nothrow @nogc
{
    return SteamAPI_SteamFriends();
}

/// Returns the `ISteamHTMLSurface` interface (`SteamAPI_SteamHTMLSurface`).
ISteamHTMLSurface* SteamHTMLSurface() nothrow @nogc
{
    return SteamAPI_SteamHTMLSurface();
}

/// Returns the `ISteamHTTP` interface (`SteamAPI_SteamHTTP`).
ISteamHTTP* SteamHTTP() nothrow @nogc
{
    return SteamAPI_SteamHTTP();
}

/// Returns the `ISteamInput` interface (`SteamAPI_SteamInput`).
ISteamInput* SteamInput() nothrow @nogc
{
    return SteamAPI_SteamInput();
}

/// Returns the `ISteamInventory` interface (`SteamAPI_SteamInventory`).
ISteamInventory* SteamInventory() nothrow @nogc
{
    return SteamAPI_SteamInventory();
}

/// Returns the `ISteamMatchmaking` interface (`SteamAPI_SteamMatchmaking`).
ISteamMatchmaking* SteamMatchmaking() nothrow @nogc
{
    return SteamAPI_SteamMatchmaking();
}

/// Returns the `ISteamMatchmakingServers` interface (`SteamAPI_SteamMatchmakingServers`).
ISteamMatchmakingServers* SteamMatchmakingServers() nothrow @nogc
{
    return SteamAPI_SteamMatchmakingServers();
}

/// Returns the `ISteamMusic` interface (`SteamAPI_SteamMusic`).
ISteamMusic* SteamMusic() nothrow @nogc
{
    return SteamAPI_SteamMusic();
}

/// Returns the `ISteamNetworking` interface (`SteamAPI_SteamNetworking`).
ISteamNetworking* SteamNetworking() nothrow @nogc
{
    return SteamAPI_SteamNetworking();
}

/// Returns the `ISteamNetworkingMessages` interface (`SteamAPI_SteamNetworkingMessages_SteamAPI`).
ISteamNetworkingMessages* SteamNetworkingMessages() nothrow @nogc
{
    return SteamAPI_SteamNetworkingMessages_SteamAPI();
}

/// Returns the `ISteamNetworkingSockets` interface (`SteamAPI_SteamNetworkingSockets_SteamAPI`).
ISteamNetworkingSockets* SteamNetworkingSockets() nothrow @nogc
{
    return SteamAPI_SteamNetworkingSockets_SteamAPI();
}

/// Returns the `ISteamNetworkingUtils` interface (`SteamAPI_SteamNetworkingUtils_SteamAPI`).
ISteamNetworkingUtils* SteamNetworkingUtils() nothrow @nogc
{
    return SteamAPI_SteamNetworkingUtils_SteamAPI();
}

/// Returns the `ISteamParentalSettings` interface (`SteamAPI_SteamParentalSettings`).
ISteamParentalSettings* SteamParentalSettings() nothrow @nogc
{
    return SteamAPI_SteamParentalSettings();
}

/// Returns the `ISteamParties` interface (`SteamAPI_SteamParties`).
ISteamParties* SteamParties() nothrow @nogc
{
    return SteamAPI_SteamParties();
}

/// Returns the `ISteamRemotePlay` interface (`SteamAPI_SteamRemotePlay`).
ISteamRemotePlay* SteamRemotePlay() nothrow @nogc
{
    return SteamAPI_SteamRemotePlay();
}

/// Returns the `ISteamRemoteStorage` interface (`SteamAPI_SteamRemoteStorage`).
ISteamRemoteStorage* SteamRemoteStorage() nothrow @nogc
{
    return SteamAPI_SteamRemoteStorage();
}

/// Returns the `ISteamScreenshots` interface (`SteamAPI_SteamScreenshots`).
ISteamScreenshots* SteamScreenshots() nothrow @nogc
{
    return SteamAPI_SteamScreenshots();
}

/// Returns the `ISteamTimeline` interface (`SteamAPI_SteamTimeline`).
ISteamTimeline* SteamTimeline() nothrow @nogc
{
    return SteamAPI_SteamTimeline();
}

/// Returns the `ISteamUGC` interface (`SteamAPI_SteamUGC`).
ISteamUGC* SteamUGC() nothrow @nogc
{
    return SteamAPI_SteamUGC();
}

/// Returns the `ISteamUser` interface (`SteamAPI_SteamUser`).
ISteamUser* SteamUser() nothrow @nogc
{
    return SteamAPI_SteamUser();
}

/// Returns the `ISteamUserStats` interface (`SteamAPI_SteamUserStats`).
ISteamUserStats* SteamUserStats() nothrow @nogc
{
    return SteamAPI_SteamUserStats();
}

/// Returns the `ISteamUtils` interface (`SteamAPI_SteamUtils`).
ISteamUtils* SteamUtils() nothrow @nogc
{
    return SteamAPI_SteamUtils();
}

/// Returns the `ISteamVideo` interface (`SteamAPI_SteamVideo`).
ISteamVideo* SteamVideo() nothrow @nogc
{
    return SteamAPI_SteamVideo();
}

/// Returns the `ISteamGameServer` interface of the game server (`SteamAPI_SteamGameServer`).
ISteamGameServer* SteamGameServer() nothrow @nogc
{
    return SteamAPI_SteamGameServer();
}

/// Returns the `ISteamHTTP` interface of the game server (`SteamAPI_SteamGameServerHTTP`).
ISteamHTTP* SteamGameServerHTTP() nothrow @nogc
{
    return SteamAPI_SteamGameServerHTTP();
}

/// Returns the `ISteamInventory` interface of the game server (`SteamAPI_SteamGameServerInventory`).
ISteamInventory* SteamGameServerInventory() nothrow @nogc
{
    return SteamAPI_SteamGameServerInventory();
}

/// Returns the `ISteamNetworking` interface of the game server (`SteamAPI_SteamGameServerNetworking`).
ISteamNetworking* SteamGameServerNetworking() nothrow @nogc
{
    return SteamAPI_SteamGameServerNetworking();
}

/// Returns the `ISteamNetworkingMessages` interface of the game server (`SteamAPI_SteamGameServerNetworkingMessages_SteamAPI`).
ISteamNetworkingMessages* SteamGameServerNetworkingMessages() nothrow @nogc
{
    return SteamAPI_SteamGameServerNetworkingMessages_SteamAPI();
}

/// Returns the `ISteamNetworkingSockets` interface of the game server (`SteamAPI_SteamGameServerNetworkingSockets_SteamAPI`).
ISteamNetworkingSockets* SteamGameServerNetworkingSockets() nothrow @nogc
{
    return SteamAPI_SteamGameServerNetworkingSockets_SteamAPI();
}

/// Returns the `ISteamGameServerStats` interface of the game server (`SteamAPI_SteamGameServerStats`).
ISteamGameServerStats* SteamGameServerStats() nothrow @nogc
{
    return SteamAPI_SteamGameServerStats();
}

/// Returns the `ISteamUGC` interface of the game server (`SteamAPI_SteamGameServerUGC`).
ISteamUGC* SteamGameServerUGC() nothrow @nogc
{
    return SteamAPI_SteamGameServerUGC();
}

/// Returns the `ISteamUtils` interface of the game server (`SteamAPI_SteamGameServerUtils`).
ISteamUtils* SteamGameServerUtils() nothrow @nogc
{
    return SteamAPI_SteamGameServerUtils();
}

unittest
{
    // Each accessor returns the handle type of its interface.
    static assert(is(typeof(SteamUser()) == ISteamUser*));
    static assert(is(typeof(SteamGameServerUtils()) == ISteamUtils*));
    static assert(is(typeof(SteamNetworkingUtils()) == ISteamNetworkingUtils*));
    static assert(is(typeof(SteamGameServerNetworkingSockets()) == ISteamNetworkingSockets*));
}

/// Without the library (not loaded, or lacking an accessor) every accessor
/// returns null instead of calling through a null function pointer.
version (SteamworksDynamic) unittest
{
    import steamworks.loader : isSteamworksLoaded;

    if (isSteamworksLoaded())
        return;
    size_t checked;
    static foreach (name; __traits(allMembers, steamworks.accessors))
    {
        static if (is(typeof(__traits(getMember, steamworks.accessors, name)) == function))
        {
            assert(__traits(getMember, steamworks.accessors, name)() is null, name);
            ++checked;
        }
    }
    assert(checked >= 30);
    assert(SteamAPI_SteamUser() is null);
    assert(SteamClient() is null && SteamGameServerClient() is null);
}

/// An accessor the loaded library lacks reports null.
version (SteamworksDynamic) unittest
{
    const saved = SteamAPI_SteamUtils_v010;
    scope (exit)
        SteamAPI_SteamUtils_v010 = saved;
    SteamAPI_SteamUtils_v010 = null;
    assert(SteamUtils() is null);
    assert(SteamAPI_SteamUtils() is null);
}
