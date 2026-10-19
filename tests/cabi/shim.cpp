// Stand-in implementations of flat API functions whose calling convention is
// easy to get wrong: structs returned and passed by value (some byte-packed),
// and mixed integer and floating point arguments. They are compiled by clang
// against the SDK headers, so their signatures are exactly the SDK's, and
// linked into tests/cabi/main.d in place of libsteam_api.
#include "steam/steam_api_flat.h"
#include "steam/steam_gameserver.h"

static bool g_streq(const char *a, const char *b)
{
	while (*a && *a == *b) { ++a; ++b; }
	return *a == *b;
}

S_API InputAnalogActionData_t SteamAPI_ISteamInput_GetAnalogActionData( ISteamInput* self, InputHandle_t inputHandle, InputAnalogActionHandle_t analogActionHandle )
{
	InputAnalogActionData_t d;
	d.eMode = (EInputSourceMode)( analogActionHandle & 0xff );
	d.x = (float)( inputHandle >> 32 ) + 0.5f;
	d.y = -2.25f;
	d.bActive = self == (ISteamInput *)0x10;
	return d;
}

S_API InputDigitalActionData_t SteamAPI_ISteamInput_GetDigitalActionData( ISteamInput* self, InputHandle_t inputHandle, InputDigitalActionHandle_t digitalActionHandle )
{
	InputDigitalActionData_t d;
	d.bState = inputHandle == 0x1122334455667788ull;
	d.bActive = digitalActionHandle == 3;
	return d;
}

S_API InputMotionData_t SteamAPI_ISteamInput_GetMotionData( ISteamInput* self, InputHandle_t inputHandle )
{
	InputMotionData_t d;
	float *f = &d.rotQuatX;
	for ( int i = 0; i < 10; ++i )
		f[i] = (float)inputHandle + (float)i * 0.25f;
	return d;
}

S_API InputAnalogActionData_t SteamAPI_ISteamController_GetAnalogActionData( ISteamController* self, ControllerHandle_t controllerHandle, ControllerAnalogActionHandle_t analogActionHandle )
{
	return SteamAPI_ISteamInput_GetAnalogActionData( (ISteamInput *)self, controllerHandle, analogActionHandle );
}

S_API SteamIPAddress_t SteamAPI_ISteamGameServer_GetPublicIP( ISteamGameServer* self )
{
	SteamIPAddress_t ip = {};
	ip.m_eType = k_ESteamIPTypeIPv6;
	for ( int i = 0; i < 16; ++i )
		ip.m_rgubIPv6[i] = (uint8)( i * 3 + 1 );
	return ip;
}

S_API SNetListenSocket_t SteamAPI_ISteamNetworking_CreateListenSocket( ISteamNetworking* self, int nVirtualP2PPort, SteamIPAddress_t nIP, uint16 nPort, bool bAllowUseOfPacketRelay )
{
	if ( nIP.m_eType != k_ESteamIPTypeIPv4 || !bAllowUseOfPacketRelay )
		return 0;
	return nIP.m_unIPv4 ^ ( (uint32)nPort << 8 ) ^ (uint32)nVirtualP2PPort;
}

S_API bool SteamAPI_ISteamParties_GetBeaconLocationData( ISteamParties* self, SteamPartyBeaconLocation_t BeaconLocation, ESteamPartyBeaconLocationData eData, char * pchDataStringOut, int cchDataStringOut )
{
	if ( cchDataStringOut < 2 )
		return false;
	pchDataStringOut[0] = (char)( 'A' + (int)BeaconLocation.m_eType );
	pchDataStringOut[1] = 0;
	return BeaconLocation.m_ulLocationID == 0xabcdef0123456789ull && eData == k_ESteamPartyBeaconLocationDataIconURLLarge;
}

S_API bool SteamAPI_ISteamUserStats_UpdateAvgRateStat( ISteamUserStats* self, const char * pchName, float flCountThisSession, double dSessionLength )
{
	return g_streq( pchName, "rate" ) && flCountThisSession == 2.5f && dSessionLength == 7.25;
}

S_API void SteamAPI_ISteamInput_SetLEDColor( ISteamInput* self, InputHandle_t inputHandle, uint8 nColorR, uint8 nColorG, uint8 nColorB, unsigned int nFlags )
{
	*(uint32 *)self = ( (uint32)nColorR << 24 ) | ( (uint32)nColorG << 16 ) | ( (uint32)nColorB << 8 ) | ( nFlags & 0xff );
}

S_API bool SteamAPI_ISteamUserStats_GetStatFloat( ISteamUserStats* self, const char * pchName, float * pData )
{
	*pData = 0.125f;
	return true;
}

S_API EBeginAuthSessionResult SteamAPI_ISteamUser_BeginAuthSession( ISteamUser* self, const void * pAuthTicket, int cbAuthTicket, uint64_steamid steamID )
{
	return steamID == 76561197960287930ull && cbAuthTicket == -5 ? k_EBeginAuthSessionResultExpiredTicket : k_EBeginAuthSessionResultOK;
}

S_API int SteamAPI_ISteamNetworkingUtils_EstimatePingTimeBetweenTwoLocations( ISteamNetworkingUtils* self, const SteamNetworkPingLocation_t & location1, const SteamNetworkPingLocation_t & location2 )
{
	return location1.m_data[0] - location2.m_data[511];
}

// The D modules' unversioned accessors reference these exports.
S_API ISteamController *SteamAPI_SteamController_v008() { return nullptr; }
S_API ISteamNetworking *SteamAPI_SteamGameServerNetworking_v006() { return nullptr; }
S_API ISteamGameServer *SteamAPI_SteamGameServer_v015() { return nullptr; }
S_API ISteamInput *SteamAPI_SteamInput_v006() { return nullptr; }
S_API ISteamMatchmakingServers *SteamAPI_SteamMatchmakingServers_v002() { return nullptr; }
S_API ISteamMatchmaking *SteamAPI_SteamMatchmaking_v009() { return nullptr; }
S_API ISteamNetworkingUtils *SteamAPI_SteamNetworkingUtils_SteamAPI_v004() { return nullptr; }
S_API ISteamNetworking *SteamAPI_SteamNetworking_v006() { return nullptr; }
S_API ISteamParties *SteamAPI_SteamParties_v002() { return nullptr; }
S_API ISteamUserStats *SteamAPI_SteamUserStats_v013() { return nullptr; }
S_API ISteamUser *SteamAPI_SteamUser_v023() { return nullptr; }
