/// Conveniences for `CSteamID`: D-style accessors, text rendering in Steam's
/// "[U:1:22202]" form and parsing of the common textual forms.
///
/// The accessors are free functions so they read naturally with UFCS
/// (`id.accountID`, `id.universe`) while `CSteamID` keeps exactly its C++
/// members.
module steamworks.steamid;

import steamworks.raw.consts : k_unSteamUserDefaultInstance;
import steamworks.raw.enums : EAccountType, EChatSteamIDInstanceFlags, EUniverse;
import steamworks.raw.steamid : CSteamID;
import steamworks.raw.types : AccountID_t;

/// The account ID (bits 0-31).
AccountID_t accountID(const CSteamID id) @safe pure nothrow @nogc
{
    return id.GetAccountID();
}

/// The account instance (bits 32-51).
uint accountInstance(const CSteamID id) @safe pure nothrow @nogc
{
    return id.GetUnAccountInstance();
}

/// The account type (bits 52-55).
EAccountType accountType(const CSteamID id) @safe pure nothrow @nogc
{
    return id.GetEAccountType();
}

/// The universe (bits 56-63).
EUniverse universe(const CSteamID id) @safe pure nothrow @nogc
{
    return id.GetEUniverse();
}

/// The 64-bit representation the flat API passes as `uint64_steamid`.
ulong toUint64(const CSteamID id) @safe pure nothrow @nogc
{
    return id.ConvertToUint64();
}

/// The instance a Steam ID text with type letter `letter` and no instance
/// stands for: the one `CSteamID.Set` gives the type (0 for clans and game
/// servers, `k_unSteamUserDefaultInstance` otherwise), the chat flag the
/// letter names for chats, and 0 for the nil ID's 'I'.
private uint impliedInstance(char letter) @safe pure nothrow @nogc
{
    switch (letter)
    {
    case 'U':
    case 'M':
    case 'A':
    case 'P':
    case 'C':
    case 'a':
        return k_unSteamUserDefaultInstance;
    case 'c':
        return EChatSteamIDInstanceFlags.k_EChatInstanceFlagClan;
    case 'L':
        return EChatSteamIDInstanceFlags.k_EChatInstanceFlagLobby;
    default:
        return 0;
    }
}

/// Characters `formatSteamID` may write, enough for any Steam ID.
enum size_t steamIDMaxLength = 32;

/// Renders `id` the way Steam does (`CSteamID::Render`) into `buffer` and
/// returns the written part: a letter for the account type, the universe, the
/// account ID and, where it is significant, the instance. For example
/// "[U:1:22202]" (an individual), "[g:1:4]" (a clan), "[L:1:123]" (a lobby)
/// or "[A:1:5:7]" (an anonymous game server). Where Steam would leave out an
/// instance other than the one the type implies, it is written, so that
/// `parseSteamID` always gives back `id`. `buffer` should hold at least
/// `steamIDMaxLength` characters; the output is truncated to fit otherwise.
char[] formatSteamID(const CSteamID id, return scope char[] buffer) @safe pure nothrow @nogc
{
    size_t n;
    void put(char c)
    {
        if (n < buffer.length)
            buffer[n++] = c;
    }

    void putNumber(ulong v)
    {
        char[20] digits;
        size_t d;
        do
        {
            digits[d++] = cast(char)('0' + v % 10);
            v /= 10;
        }
        while (v);
        while (d)
            put(digits[--d]);
    }

    const instance = id.GetUnAccountInstance();
    char letter;
    // Steam always renders the instance of these two types.
    bool withInstance;
    switch (id.GetEAccountType()) with (EAccountType)
    {
    case k_EAccountTypeInvalid:
        letter = 'I';
        break;
    case k_EAccountTypeIndividual:
        letter = 'U';
        break;
    case k_EAccountTypeMultiseat:
        letter = 'M';
        withInstance = true;
        break;
    case k_EAccountTypeGameServer:
        letter = 'G';
        break;
    case k_EAccountTypeAnonGameServer:
        letter = 'A';
        withInstance = true;
        break;
    case k_EAccountTypePending:
        letter = 'P';
        break;
    case k_EAccountTypeContentServer:
        letter = 'C';
        break;
    case k_EAccountTypeClan:
        letter = 'g';
        break;
    case k_EAccountTypeChat:
        if (instance & EChatSteamIDInstanceFlags.k_EChatInstanceFlagClan)
            letter = 'c';
        else if (instance & EChatSteamIDInstanceFlags.k_EChatInstanceFlagLobby)
            letter = 'L';
        else
            letter = 'T';
        break;
    case k_EAccountTypeAnonUser:
        letter = 'a';
        break;
    default:
        letter = 'i';
        break;
    }
    // Steam leaves out an instance the letter implies; one that differs is
    // kept so that the text parses back to the same ID.
    if (instance != impliedInstance(letter))
        withInstance = true;
    put('[');
    put(letter);
    put(':');
    putNumber(id.GetEUniverse());
    put(':');
    putNumber(id.GetAccountID());
    if (withInstance)
    {
        put(':');
        putNumber(instance);
    }
    put(']');
    return buffer[0 .. n];
}

/// Renders `id` like `formatSteamID`, as a new GC-allocated string.
string toSteam3String(const CSteamID id) @safe pure nothrow
{
    char[steamIDMaxLength] buffer;
    return formatSteamID(id, buffer[]).idup;
}

/// Renders an individual account's ID in the legacy "STEAM_X:Y:Z" form, where
/// X is the universe, Y the low bit of the account ID and Z the rest. Other
/// account types have no such form and give `null`.
string toSteam2String(const CSteamID id) @safe pure nothrow
{
    import std.conv : to;

    if (id.GetEAccountType() != EAccountType.k_EAccountTypeIndividual)
        return null;
    const account = id.GetAccountID();
    return "STEAM_" ~ to!string(cast(int) id.GetEUniverse()) ~ ":" ~ to!string(
            account & 1) ~ ":" ~ to!string(account >> 1);
}

/// Parses a Steam ID written as a decimal 64-bit number ("76561197960287930"),
/// in Steam's rendered form with or without brackets ("[U:1:22202]",
/// "[A:1:5:7]", "U:1:22202"), or in the legacy "STEAM_X:Y:Z" form (where
/// universe 0 means public). Without an instance, the ID gets the one
/// `CSteamID.Set` assigns its type (0 for clans and game servers, 1 for most
/// others) or the chat flag of 'c' and 'L'; "[I:0:0]" is `k_steamIDNil`.
/// Returns whether `text` was valid; `id` is `k_steamIDNil` otherwise.
bool parseSteamID(scope const(char)[] text, out CSteamID id) @safe pure nothrow @nogc
{
    static bool number(ref scope const(char)[] s, out ulong v, ulong max)
    {
        size_t i;
        while (i < s.length && s[i] >= '0' && s[i] <= '9')
        {
            const digit = s[i] - '0';
            if (digit > max || v > (max - digit) / 10)
                return false;
            v = v * 10 + digit;
            ++i;
        }
        s = s[i .. $];
        return i > 0;
    }

    static bool skip(ref scope const(char)[] s, char c)
    {
        if (!s.length || s[0] != c)
            return false;
        s = s[1 .. $];
        return true;
    }

    const(char)[] s = text;
    ulong a, b, c;
    if (s.length > 6 && s[0 .. 6] == "STEAM_")
    {
        s = s[6 .. $];
        if (!number(s, a, EUniverse.k_EUniverseMax - 1) || !skip(s, ':') || !number(s, b, 1)
                || !skip(s, ':') || !number(s, c, uint.max >> 1) || s.length)
            return false;
        const universe = a == 0 ? EUniverse.k_EUniversePublic : cast(EUniverse) a;
        id = CSteamID(cast(uint)(c * 2 + b), universe, EAccountType.k_EAccountTypeIndividual);
        return true;
    }
    if (s.length && s[0] >= '0' && s[0] <= '9')
    {
        if (!number(s, a, ulong.max) || s.length)
            return false;
        id = CSteamID(a);
        return true;
    }

    const bracketed = skip(s, '[');
    if (!s.length)
        return false;
    const letter = s[0];
    s = s[1 .. $];
    if (!skip(s, ':') || !number(s, a, 255) || !skip(s, ':') || !number(s, b, uint.max))
        return false;
    bool hasInstance;
    if (skip(s, ':'))
    {
        if (!number(s, c, (1UL << 20) - 1))
            return false;
        hasInstance = true;
    }
    if (bracketed && !skip(s, ']'))
        return false;
    if (s.length)
        return false;

    EAccountType type;
    switch (letter)
    {
    case 'I':
        type = EAccountType.k_EAccountTypeInvalid;
        break;
    case 'U':
        type = EAccountType.k_EAccountTypeIndividual;
        break;
    case 'M':
        type = EAccountType.k_EAccountTypeMultiseat;
        break;
    case 'G':
        type = EAccountType.k_EAccountTypeGameServer;
        break;
    case 'A':
        type = EAccountType.k_EAccountTypeAnonGameServer;
        break;
    case 'P':
        type = EAccountType.k_EAccountTypePending;
        break;
    case 'C':
        type = EAccountType.k_EAccountTypeContentServer;
        break;
    case 'g':
        type = EAccountType.k_EAccountTypeClan;
        break;
    case 'T':
        type = EAccountType.k_EAccountTypeChat;
        break;
    case 'c':
    case 'L':
        type = EAccountType.k_EAccountTypeChat;
        break;
    case 'a':
        type = EAccountType.k_EAccountTypeAnonUser;
        break;
    default:
        return false;
    }
    const instance = hasInstance ? cast(uint) c : impliedInstance(letter);
    id = CSteamID(cast(uint) b, instance, cast(EUniverse) a, type);
    return true;
}

unittest
{
    const id = CSteamID(76_561_197_960_287_930UL);
    assert(id.accountID == 22_202);
    assert(id.accountInstance == 1);
    assert(id.accountType == EAccountType.k_EAccountTypeIndividual);
    assert(id.universe == EUniverse.k_EUniversePublic);
    assert(id.toUint64 == 76_561_197_960_287_930UL);
}

unittest
{
    assert(CSteamID(76_561_197_960_287_930UL).toSteam3String == "[U:1:22202]");
    assert(CSteamID(22_202, 2, EUniverse.k_EUniversePublic, EAccountType.k_EAccountTypeIndividual)
            .toSteam3String == "[U:1:22202:2]");
    assert(CSteamID(4, EUniverse.k_EUniversePublic, EAccountType.k_EAccountTypeClan).toSteam3String == "[g:1:4]");
    assert(CSteamID(5, 7, EUniverse.k_EUniverseBeta, EAccountType.k_EAccountTypeAnonGameServer)
            .toSteam3String == "[A:2:5:7]");
    assert(CSteamID(9, EUniverse.k_EUniversePublic, EAccountType.k_EAccountTypeGameServer).toSteam3String == "[G:1:9]");
    assert(CSteamID.init.toSteam3String == "[I:0:0]");
}

unittest
{
    const lobby = CSteamID(123, EChatSteamIDInstanceFlags.k_EChatInstanceFlagLobby,
            EUniverse.k_EUniversePublic, EAccountType.k_EAccountTypeChat);
    assert(lobby.toSteam3String == "[L:1:123]");
    const clanChat = CSteamID(8, EChatSteamIDInstanceFlags.k_EChatInstanceFlagClan,
            EUniverse.k_EUniversePublic, EAccountType.k_EAccountTypeChat);
    assert(clanChat.toSteam3String == "[c:1:8]");
    const chat = CSteamID(8, 0, EUniverse.k_EUniversePublic, EAccountType.k_EAccountTypeChat);
    assert(chat.toSteam3String == "[T:1:8]");
}

unittest
{
    // The longest rendering fits steamIDMaxLength.
    const big = CSteamID(uint.max, (1 << 20) - 1, cast(EUniverse) 255, EAccountType.k_EAccountTypeAnonGameServer);
    char[steamIDMaxLength] buf;
    assert(formatSteamID(big, buf[]) == "[A:255:4294967295:1048575]");
}

@nogc nothrow unittest
{
    char[4] small;
    assert(formatSteamID(CSteamID(76_561_197_960_287_930UL), small[]) == "[U:1");
}

unittest
{
    assert(CSteamID(76_561_197_960_287_930UL).toSteam2String == "STEAM_1:0:11101");
    assert(CSteamID(22_203, EUniverse.k_EUniversePublic, EAccountType.k_EAccountTypeIndividual)
            .toSteam2String == "STEAM_1:1:11101");
    assert(CSteamID(4, EUniverse.k_EUniversePublic, EAccountType.k_EAccountTypeClan).toSteam2String is null);
}

unittest
{
    CSteamID id;
    assert(parseSteamID("76561197960287930", id) && id.toUint64 == 76_561_197_960_287_930UL);
    assert(parseSteamID("[U:1:22202]", id) && id.toUint64 == 76_561_197_960_287_930UL);
    assert(parseSteamID("U:1:22202", id) && id.toUint64 == 76_561_197_960_287_930UL);
    assert(parseSteamID("STEAM_0:0:11101", id) && id.toUint64 == 76_561_197_960_287_930UL);
    assert(parseSteamID("STEAM_1:0:11101", id) && id.toUint64 == 76_561_197_960_287_930UL);
}

unittest
{
    // Every rendering parses back to the same ID.
    const ids = [
        CSteamID(76_561_197_960_287_930UL),
        CSteamID(22_202, 2, EUniverse.k_EUniversePublic, EAccountType.k_EAccountTypeIndividual),
        CSteamID(4, EUniverse.k_EUniversePublic, EAccountType.k_EAccountTypeClan),
        CSteamID(5, 7, EUniverse.k_EUniverseBeta, EAccountType.k_EAccountTypeAnonGameServer),
        CSteamID(123, EChatSteamIDInstanceFlags.k_EChatInstanceFlagLobby,
                EUniverse.k_EUniversePublic, EAccountType.k_EAccountTypeChat),
        CSteamID(8, EChatSteamIDInstanceFlags.k_EChatInstanceFlagClan,
                EUniverse.k_EUniversePublic, EAccountType.k_EAccountTypeChat),
        CSteamID(9, EUniverse.k_EUniversePublic, EAccountType.k_EAccountTypeGameServer),
        CSteamID(3, 4, EUniverse.k_EUniverseDev, EAccountType.k_EAccountTypeMultiseat),
        // The types Steam renders without an instance, with the instance
        // CSteamID.Set gives them, and the nil ID.
        CSteamID(5, EUniverse.k_EUniversePublic, EAccountType.k_EAccountTypeContentServer),
        CSteamID(5, EUniverse.k_EUniversePublic, EAccountType.k_EAccountTypePending),
        CSteamID(5, EUniverse.k_EUniversePublic, EAccountType.k_EAccountTypeAnonUser),
        CSteamID(5, EUniverse.k_EUniversePublic, EAccountType.k_EAccountTypeInvalid), CSteamID.init,
    ];
    foreach (expected; ids)
    {
        CSteamID parsed;
        assert(parseSteamID(expected.toSteam3String, parsed), expected.toSteam3String);
        assert(parsed == expected, expected.toSteam3String);
    }
}

unittest
{
    // An instance other than the one the text implies is kept, so the text
    // still parses back to the same ID.
    const ids = [
        CSteamID(5, 0, EUniverse.k_EUniversePublic, EAccountType.k_EAccountTypeContentServer),
        CSteamID(5, 3, EUniverse.k_EUniversePublic, EAccountType.k_EAccountTypeAnonUser),
        CSteamID(5, 1, EUniverse.k_EUniversePublic, EAccountType.k_EAccountTypeGameServer),
        CSteamID(5, 2, EUniverse.k_EUniversePublic, EAccountType.k_EAccountTypeClan),
        CSteamID(5, 2, EUniverse.k_EUniversePublic, EAccountType.k_EAccountTypeInvalid),
        CSteamID(7,
                EChatSteamIDInstanceFlags.k_EChatInstanceFlagLobby | EChatSteamIDInstanceFlags.k_EChatInstanceFlagMMSLobby,
                EUniverse.k_EUniversePublic, EAccountType.k_EAccountTypeChat),
    ];
    foreach (expected; ids)
    {
        CSteamID parsed;
        assert(parseSteamID(expected.toSteam3String, parsed), expected.toSteam3String);
        assert(parsed == expected, expected.toSteam3String);
    }
}

unittest
{
    // Text without an instance gets the one CSteamID.Set assigns.
    CSteamID id;
    assert(parseSteamID("[C:1:5]", id) && id.accountInstance == k_unSteamUserDefaultInstance);
    assert(parseSteamID("[P:1:5]", id) && id.accountInstance == k_unSteamUserDefaultInstance);
    assert(parseSteamID("[a:1:5]", id) && id.accountInstance == k_unSteamUserDefaultInstance);
    assert(parseSteamID("[G:1:5]", id) && id.accountInstance == 0);
    assert(parseSteamID("[g:1:5]", id) && id.accountInstance == 0);
    // Steam's renderings of these stay unchanged.
    assert(CSteamID(5, EUniverse.k_EUniversePublic, EAccountType.k_EAccountTypeContentServer)
            .toSteam3String == "[C:1:5]");
    assert(CSteamID(5, EUniverse.k_EUniversePublic, EAccountType.k_EAccountTypeAnonUser).toSteam3String == "[a:1:5]");
}

unittest
{
    CSteamID id = CSteamID(1UL);
    foreach (bad; [
        "", "[", "[U]", "[U:1]", "[U:1:x]", "[U:1:2", "[Z:1:2]", "U:1:2]x", "STEAM_1:2:3", "STEAM_",
        "18446744073709551616", "123abc", "[U:256:1]", "[U:1:4294967296]", "[U:1:1:1048576]"
    ])
    {
        assert(!parseSteamID(bad, id), bad);
        assert(id == CSteamID.init, bad);
    }
}
