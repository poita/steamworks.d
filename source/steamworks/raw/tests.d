/// Sanity tests for the raw bindings on the platform being compiled. The
/// exhaustive per-platform layout checks live in tests/abi.
module steamworks.raw.tests;

version (unittest)  : import std.traits : getUDAs, hasUDA;

import steamworks.loader : isSteamworksLoaded;
import steamworks.raw;
import steamworks.raw.callbacks;
import steamworks.raw.structs;

private alias moduleMembers(alias mod) = __traits(allMembers, mod);

private enum bool isStructIn(alias mod, string name) = is(__traits(getMember, mod, name) == struct);

/// Callback packing follows the headers' VALVE_CALLBACK_PACK selection.
unittest
{
    version (Windows)
        static assert(VALVE_CALLBACK_PACK == 8);
    else
        static assert(VALVE_CALLBACK_PACK == 4);
    static assert(ValvePackingSentinel_t.sizeof == (VALVE_CALLBACK_PACK_SMALL ? 24 : 32));
}

/// Callback struct sizes and offsets that depend on the packing.
unittest
{
    // uint64, uint32, bool, uint32.
    static assert(LobbyEnter_t.m_bLocked.offsetof == 12);
    static assert(LobbyEnter_t.m_EChatRoomEnterResponse.offsetof == 16);
    static assert(LobbyEnter_t.sizeof == (VALVE_CALLBACK_PACK_SMALL ? 20 : 24));
    // SteamAPICall_t, int, uint32.
    static assert(SteamAPICallCompleted_t.sizeof == 16);
    // uint64, int.
    static assert(PersonaStateChange_t.sizeof == (VALVE_CALLBACK_PACK_SMALL ? 12 : 16));
    static assert(GameOverlayActivated_t.m_nAppID.offsetof == 4);
    static assert(GameOverlayActivated_t.sizeof == 12);
}

/// Byte-packed types keep byte alignment wherever they are embedded.
unittest
{
    static assert(CSteamID.sizeof == 8 && CSteamID.alignof == 1);
    static assert(InputAnalogActionData_t.sizeof == 13 && InputAnalogActionData_t.alignof == 1);
    static assert(InputDigitalActionData_t.sizeof == 2);
    static assert(InputMotionData_t.sizeof == 40);
    static assert(SteamNetworkingIdentity.sizeof == 136);
    static assert(SteamNetConnectionInfo_t.sizeof == 696);
    static assert(SteamNetConnectionInfo_t.m_nUserData.offsetof == 136);
}

/// Naturally aligned structs follow the C ABI of the target.
unittest
{
    static assert(SteamNetworkingMessage_t.m_identityPeer.offsetof == 8 + (void*).sizeof);
    static assert(SteamNetworkingConfigValue_t.sizeof == 16);
    static assert(SteamNetworkingConfigValue_t.m_val.offsetof == 8);
    static assert(MatchMakingKeyValuePair_t.sizeof == 512);
    static assert(servernetadr_t.sizeof == 8);
    static assert(CallbackMsg_t.m_pubParam.offsetof == 8);
}

/// Spot checks of callback identifiers.
unittest
{
    static assert(SteamServersConnected_t.k_iCallback == 101);
    static assert(PersonaStateChange_t.k_iCallback == 304);
    static assert(GameOverlayActivated_t.k_iCallback == 331);
    static assert(LobbyEnter_t.k_iCallback == 504);
    static assert(SteamAPICallCompleted_t.k_iCallback == 703);
    static assert(SteamNetConnectionStatusChangedCallback_t.k_iCallback == 1221);
    static assert(LeaderboardFindResult_t.k_iCallback == k_iSteamUserStatsCallbacks + 4);
    static assert(GetTicketForWebApiResponse_t.k_iCallback == k_iSteamUserCallbacks + 68);
}

/// Callback identifiers are distinct, except that the headers deliberately
/// give GSStatsUnloaded_t the identifier of UserStatsUnloaded_t.
unittest
{
    static assert(GSStatsUnloaded_t.k_iCallback == UserStatsUnloaded_t.k_iCallback);
    string[int] seen;
    size_t count;
    static foreach (name; moduleMembers!(steamworks.raw.callbacks))
        static if (isStructIn!(steamworks.raw.callbacks, name))
            {
            {
                enum id = __traits(getMember, steamworks.raw.callbacks, name).k_iCallback;
                if (auto other = id in seen)
                    assert(name == "GSStatsUnloaded_t" && *other == "UserStatsUnloaded_t", name);
                else
                    seen[id] = name;
                ++count;
            }
        }
    assert(count == 196 && seen.length == 195);
}

/// `T.init` is all zero bytes for every struct, as C++ value-initialisation.
unittest
{
    static foreach (mod; [
        "steamworks.raw.callbacks", "steamworks.raw.structs", "steamworks.raw.manual",
        "steamworks.raw.steamid"
    ])
        static foreach (name; moduleMembers!(mixin(mod)))
            static if (isStructIn!(mixin(mod), name))
                static assert(__traits(isZeroInit, __traits(getMember, mixin(mod), name)), name);
}

/// Enum values and the unqualified C++ spellings.
unittest
{
    static assert(EResult.k_EResultOK == 1 && k_EResultOK == EResult.k_EResultOK);
    static assert(is(typeof(k_EResultOK) == EResult));
    static assert(EResult.sizeof == 4);
    static assert(k_ESteamNetworkingConnectionState_FinWait == -1);
    static assert(k_ERemoteStoragePlatformAll == 0xffff_ffff);
    static assert(is(ERemoteStoragePlatform == enum) && ERemoteStoragePlatform.sizeof == 4);
    static assert(k_EHTTPStatusCode404NotFound == 404);
    static assert(eHTMLMouseButton_Right == EHTMLMouseButton.eHTMLMouseButton_Right);
    static assert(IPCFailure_t.EFailureType.k_EFailurePipeFail == 1);
    static assert(IPCFailure_t.k_EFailurePipeFail == 1);
}

/// Constants, including header-only ones and C casts.
unittest
{
    static assert(k_uAPICallInvalid == 0);
    static assert(k_UGCHandleInvalid == ulong.max);
    static assert(k_SteamItemInstanceIDInvalid == ulong.max);
    static assert(HSERVERQUERY_INVALID == -1);
    static assert(k_cchMaxRichPresenceValueLength == 256);
    static assert(k_SteamDatagramPOPID_dev == (('d' << 16) | ('e' << 8) | 'v'));
    static assert(k_flMaxTimelineEventDuration == 600.0f);
    static assert(STEAMGAMESERVER_QUERY_PORT_SHARED == 0xffff);
    static assert(GetTicketForWebApiResponse_t.k_nCubTicketMaxLength == 2560);
    static assert(SteamNetworkingFakeIPResult_t.k_nMaxReturnPorts == 8);
}

/// Typedef widths, including the platform-dependent ones.
unittest
{
    static assert(uint64_steamid.sizeof == 8 && SteamAPICall_t.sizeof == 8);
    static assert(HSteamPipe.sizeof == 4 && AppId_t.sizeof == 4);
    static assert(intp.sizeof == (void*).sizeof && uintp.sizeof == (void*).sizeof);
    static assert(SteamErrMsg.sizeof == 1024 && SteamNetworkingErrMsg.sizeof == 1024);
    static assert(is(ControllerAnalogActionData_t == InputAnalogActionData_t));
    version (Windows) static assert(lint64.sizeof == 8);
}

/// Interface version strings.
unittest
{
    static assert(STEAMUSER_INTERFACE_VERSION == "SteamUser023");
    static assert(STEAMCLIENT_INTERFACE_VERSION == "SteamClient023");
    static assert(STEAMNETWORKINGSOCKETS_INTERFACE_VERSION == "SteamNetworkingSockets012");
}

/// Methods take the interface as `self`; accessors return it.
unittest
{
    static assert(is(typeof(&SteamAPI_SteamUser) == ISteamUser* function() nothrow @nogc));
    static assert(is(typeof(SteamAPI_ISteamUser_GetSteamID(null)) == uint64_steamid));
    static assert(is(typeof(SteamAPI_ISteamFriends_GetPersonaName(null)) == const(char)*));
    ISteamNetworkingSockets* sockets = null;
    SteamNetworkingIPAddr addr;
    addr.Clear();
    static assert(__traits(compiles, SteamAPI_ISteamNetworkingSockets_CreateListenSocketIP(sockets, addr, 0, null)));
}

/// SteamNetworkingIdentity's inline generic-bytes accessors.
@system unittest
{
    SteamNetworkingIdentity id;
    immutable ubyte[3] bytes = [1, 2, 3];
    assert(id.SetGenericBytes(bytes.ptr, bytes.length));
    int n = -1;
    const p = id.GetGenericBytes(n);
    assert(n == 3 && p[0 .. 3] == bytes);
}

/// Asynchronous functions carry their call-result struct as a UDA.
unittest
{
    static assert(hasUDA!(SteamAPI_ISteamUserStats_FindLeaderboard, SteamCallResult));
    alias uda = getUDAs!(SteamAPI_ISteamUserStats_FindLeaderboard, SteamCallResult)[0];
    static assert(is(typeof(uda).Result == LeaderboardFindResult_t));
    static assert(!hasUDA!(SteamAPI_ISteamUser_GetSteamID, SteamCallResult));
    static assert(hasUDA!(SteamAPI_ISteamVideo_GetOPFSettings, SteamCallback));
}

/// The callback UDAs name the callbacks a call makes Steam post: both device
/// callbacks for EnableDeviceCallbacks, none for EnableActionEventCallbacks
/// (it calls the function pointer it receives instead).
unittest
{
    alias dev = getUDAs!(SteamAPI_ISteamInput_EnableDeviceCallbacks, SteamCallback);
    static assert(dev.length == 1);
    alias posted = typeof(dev[0]).Callbacks;
    static assert(posted.length == 2);
    static assert(is(posted[0] == SteamInputDeviceConnected_t));
    static assert(is(posted[1] == SteamInputDeviceDisconnected_t));
    static assert(!hasUDA!(SteamAPI_ISteamInput_EnableActionEventCallbacks, SteamCallback));
}

/// A function posting a single callback names it as `Callback`.
unittest
{
    alias opf = getUDAs!(SteamAPI_ISteamVideo_GetOPFSettings, SteamCallback)[0];
    static assert(is(typeof(opf).Callback == GetOPFSettingsResult_t));
    static assert(typeof(opf).Callbacks.length == 1);
}

/// POP IDs pack a 3-character code as 0x00aabbcc, the "dev" constant included.
unittest
{
    assert(CalculateSteamNetworkingPOPIDFromString("dev") == k_SteamDatagramPOPID_dev);
    assert(CalculateSteamNetworkingPOPIDFromString("iad") == 0x69_6164);
    char[5] code;
    GetSteamNetworkingLocationPOPStringFromID(CalculateSteamNetworkingPOPIDFromString("iad"), code);
    assert(code == "iad\0\0");
}

/// A 4-character code "abcd" packs as 0xddaabbcc and renders back.
unittest
{
    const id = CalculateSteamNetworkingPOPIDFromString("abcd");
    assert(id == 0x6461_6263);
    char[8] code = 'x';
    GetSteamNetworkingLocationPOPStringFromID(id, code);
    assert(code[0 .. 5] == "abcd\0" && code[5] == 'x');
}

/// Short codes stop at the terminator instead of reading past it.
unittest
{
    assert(CalculateSteamNetworkingPOPIDFromString("") == 0);
    // Bytes after the terminator are never read.
    immutable char[3] one = ['a', '\0', 'z'];
    assert(CalculateSteamNetworkingPOPIDFromString(one.ptr) == 0x61_0000);
    immutable char[4] two = ['a', 'b', '\0', 'z'];
    assert(CalculateSteamNetworkingPOPIDFromString(two.ptr) == 0x61_6200);
    // High bytes are taken unsigned.
    assert(CalculateSteamNetworkingPOPIDFromString("\xff\xfe\xfd") == 0xff_fefd);
}

/// The C++ callback interfaces are subclassable from D.
unittest
{
    static extern (C++) class Ping : ISteamMatchmakingPingResponse
    {
        int responded;

        override void ServerResponded(ref gameserveritem_t server) nothrow
        {
            responded = server.m_nPing;
        }

        override void ServerFailedToRespond() nothrow
        {
            responded = -1;
        }
    }

    auto p = new Ping;
    gameserveritem_t item;
    item.m_nPing = 42;
    ISteamMatchmakingPingResponse base = p;
    base.ServerResponded(item);
    assert(p.responded == 42);
    base.ServerFailedToRespond();
    assert(p.responded == -1);
}

/// The function table is complete and unique.
unittest
{
    static assert(steamworksFunctionNames.length == steamworksFunctionCount);
    bool[string] seen;
    foreach (n; steamworksFunctionNames)
    {
        assert(n !in seen, n);
        seen[n] = true;
    }
    foreach (n; steamworksUnboundExports)
        assert(n !in seen, n);
    size_t visited;
    steamworksForEachFunction((string name, void* address) nothrow @nogc {
        assert(name == steamworksFunctionNames[visited]);
        ++visited;
    });
    assert(visited == steamworksFunctionCount);
}

/// Dynamic-mode pointers start out null.
version (SteamworksDynamic) unittest
{
    if (isSteamworksLoaded())
        return;
    assert(SteamAPI_IsSteamRunning is null);
    steamworksForEachFunction((string, void* address) nothrow @nogc { assert(address is null); });
}
