/// Calls stand-in implementations of flat API functions (shim.cpp, compiled
/// by clang against the SDK headers) through the D declarations, checking
/// that both compilers pass and return values exactly as the C ABI requires.
module main;

import core.stdc.stdio : printf;
import core.stdc.string : strcmp;

import steamworks.raw.enums;
import steamworks.raw.isteamcontroller;
import steamworks.raw.isteamgameserver;
import steamworks.raw.isteaminput;
import steamworks.raw.isteamnetworking;
import steamworks.raw.isteammatchmaking;
import steamworks.raw.isteamnetworkingutils;
import steamworks.raw.isteamuser;
import steamworks.raw.isteamuserstats;
import steamworks.raw.interfaces;
import steamworks.raw.manual;
import steamworks.raw.structs;

int failures;

void check(bool ok, const(char)* what, size_t line = __LINE__)
{
    if (!ok)
    {
        printf("FAILED line %zu: %s\n", line, what);
        ++failures;
    }
}

int main()
{
    auto input = cast(ISteamInput*) cast(void*) 0x10;

    const a = SteamAPI_ISteamInput_GetAnalogActionData(input, 7UL << 32, 0x203);
    check(a.eMode == cast(EInputSourceMode) 3 && a.x == 7.5f && a.y == -2.25f && a.bActive,
            "13-byte packed struct return");
    const ca = SteamAPI_ISteamController_GetAnalogActionData(cast(ISteamController*) input, 9UL << 32, 1);
    check(ca.x == 9.5f && ca.bActive, "packed struct return through ISteamController");

    const d = SteamAPI_ISteamInput_GetDigitalActionData(input, 0x1122334455667788UL, 3);
    check(d.bState && d.bActive, "2-byte struct return");

    const m = SteamAPI_ISteamInput_GetMotionData(input, 100);
    check(m.rotQuatX == 100.0f && m.rotVelZ == 102.25f, "40-byte struct return");

    const ip = SteamAPI_ISteamGameServer_GetPublicIP(null);
    check(ip.m_eType == ESteamIPType.k_ESteamIPTypeIPv6 && ip.m_rgubIPv6[0] == 1 && ip.m_rgubIPv6[15] == 46,
            "20-byte packed struct return");

    SteamIPAddress_t v4 = SteamIPAddress_t.IPv4Loopback();
    check(SteamAPI_ISteamNetworking_CreateListenSocket(null, 5, v4, 0x1234, true) == (0x7f00_0001 ^ (0x1234 << 8) ^ 5),
            "20-byte packed struct parameter");

    SteamPartyBeaconLocation_t loc;
    loc.m_eType = ESteamPartyBeaconLocationType.k_ESteamPartyBeaconLocationType_ChatGroup;
    loc.m_ulLocationID = 0xabcdef0123456789UL;
    char[4] buf = 0;
    check(SteamAPI_ISteamParties_GetBeaconLocationData(null, loc,
            ESteamPartyBeaconLocationData.k_ESteamPartyBeaconLocationDataIconURLLarge, buf.ptr, buf.length),
            "callback-packed struct parameter");
    check(buf[0] == 'A' + 1, "callback-packed struct parameter (enum)");

    check(SteamAPI_ISteamUserStats_UpdateAvgRateStat(null, "rate", 2.5f, 7.25), "string, float and double arguments");

    uint led;
    SteamAPI_ISteamInput_SetLEDColor(cast(ISteamInput*)&led, 1, 0x11, 0x22, 0x33, 0x1ff);
    check(led == 0x112233ff, "uint8 arguments");

    float f = 0;
    check(SteamAPI_ISteamUserStats_GetStatFloat(null, "x", &f) && f == 0.125f, "float out parameter");

    check(SteamAPI_ISteamUser_BeginAuthSession(null, null, -5, 76_561_197_960_287_930UL)
            == EBeginAuthSessionResult.k_EBeginAuthSessionResultExpiredTicket, "uint64 argument and enum return");

    SteamNetworkPingLocation_t l1, l2;
    l1.m_data[0] = 50;
    l2.m_data[511] = 8;
    check(SteamAPI_ISteamNetworkingUtils_EstimatePingTimeBetweenTwoLocations(null, l1, l2) == 42,
            "const reference parameters");

    if (failures)
        return 1;
    printf("C ABI calls passed\n");
    return 0;
}
