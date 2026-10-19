/// Text conversions for `SteamNetworkingIPAddr` and `SteamNetworkingIdentity`
/// with D strings, using the library's own formatting and parsing
/// (`SteamAPI_SteamNetworkingIPAddr_ToString` and friends), so the text is
/// exactly what Steam produces and accepts.
///
/// These work without Steam running or initialized, but with the "dynamic"
/// configuration the library must be loaded.
module steamworks.networking;

import steamworks.raw.manual : SteamNetworkingIdentity, SteamNetworkingIPAddr;
import steamworks.raw.steamnetworkingtypes;
import steamworks.strings : fromCString, tempCString;

/// Renders `addr` into `buffer` ("192.168.0.1:27015", "[::1]:27015", or
/// without the port), returning the written part. A buffer shorter than
/// `SteamNetworkingIPAddr.k_cchMaxString` may truncate the text.
char[] formatIPAddr(ref const SteamNetworkingIPAddr addr, return scope char[] buffer, bool withPort = true) nothrow @nogc
{
    if (!buffer.length)
        return buffer;
    buffer[0] = '\0';
    SteamAPI_SteamNetworkingIPAddr_ToString(cast(SteamNetworkingIPAddr*)&addr, buffer.ptr,
            cast(uint) buffer.length, withPort);
    return fromCString(buffer);
}

/// Renders `addr` like `formatIPAddr`, as a new GC-allocated string.
string ipAddrToString(ref const SteamNetworkingIPAddr addr, bool withPort = true) nothrow
{
    char[SteamNetworkingIPAddr.k_cchMaxString] buffer;
    return formatIPAddr(addr, buffer[], withPort).idup;
}

/// Parses an IPv4 or IPv6 address with an optional port ("1.2.3.4:27015",
/// "[::1]:27015", "::1"). Returns whether `text` was valid; `addr` is cleared
/// otherwise.
bool parseIPAddr(scope const(char)[] text, out SteamNetworkingIPAddr addr) nothrow @nogc
{
    auto s = tempCString(text);
    if (s.ptr is null || !SteamAPI_SteamNetworkingIPAddr_ParseString(&addr, s.ptr))
    {
        addr.Clear();
        return false;
    }
    return true;
}

/// Renders `identity` into `buffer` ("steamid:76561197960287930",
/// "ip:1.2.3.4:27015", "str:name", ...), returning the written part. A buffer
/// shorter than `SteamNetworkingIdentity.k_cchMaxString` may truncate the text.
char[] formatIdentity(ref const SteamNetworkingIdentity identity, return scope char[] buffer) nothrow @nogc
{
    if (!buffer.length)
        return buffer;
    buffer[0] = '\0';
    SteamAPI_SteamNetworkingIdentity_ToString(cast(SteamNetworkingIdentity*)&identity,
            buffer.ptr, cast(uint) buffer.length);
    return fromCString(buffer);
}

/// Renders `identity` like `formatIdentity`, as a new GC-allocated string.
string identityToString(ref const SteamNetworkingIdentity identity) nothrow
{
    char[SteamNetworkingIdentity.k_cchMaxString] buffer;
    return formatIdentity(identity, buffer[]).idup;
}

/// Parses an identity in the form `formatIdentity` produces. Returns whether
/// `text` was valid; `identity` is cleared otherwise.
bool parseIdentity(scope const(char)[] text, out SteamNetworkingIdentity identity) nothrow @nogc
{
    auto s = tempCString(text);
    if (s.ptr is null || !SteamAPI_SteamNetworkingIdentity_ParseString(&identity, s.ptr))
    {
        identity.Clear();
        return false;
    }
    return true;
}

unittest
{
    // Empty buffers are left alone, before any library call.
    SteamNetworkingIPAddr addr;
    SteamNetworkingIdentity identity;
    assert(formatIPAddr(addr, null).length == 0);
    assert(formatIdentity(identity, null).length == 0);
}
