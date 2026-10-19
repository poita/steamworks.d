/// `CSteamID` and `CGameID` (steamclientpublic.h).
///
/// Both are 64-bit values with byte alignment (`#pragma pack(1)`). The C++
/// bitfields are exposed through accessors with the C++ method names; the
/// flat API passes these types as plain `uint64_steamid` / `uint64_gameid`.
module steamworks.raw.steamid;

import steamworks.raw.consts : k_unSteamAccountIDMask, k_unSteamAccountInstanceMask,
    k_unSteamUserDefaultInstance, k_uAppIdInvalid;
import steamworks.raw.enums;
import steamworks.raw.types : AccountID_t;

/// Steam ID: account ID (bits 0-31), account instance (32-51), account type
/// (52-55) and universe (56-63).
struct CSteamID
{
align(1):
    /// Storage, as the C++ `union SteamID_t`.
    union SteamID_t
    {
    align(1):
        /// All 64 bits.
        ulong m_unAll64Bits;
    }

    /// The packed identifier.
    SteamID_t m_steamid;

    /// Constructs from the 64-bit representation.
    this(ulong ulSteamID) @safe pure nothrow @nogc
    {
        SetFromUint64(ulSteamID);
    }

    /// Constructs from an account ID with the default instance for the type.
    this(uint unAccountID, EUniverse eUniverse, EAccountType eAccountType) @safe pure nothrow @nogc
    {
        Set(unAccountID, eUniverse, eAccountType);
    }

    /// Constructs from all four components.
    this(uint unAccountID, uint unAccountInstance, EUniverse eUniverse, EAccountType eAccountType) @safe pure nothrow @nogc
    {
        InstancedSet(unAccountID, unAccountInstance, eUniverse, eAccountType);
    }

    private void setBits(uint shift, uint width, ulong value) @safe pure nothrow @nogc
    {
        const mask = ((1UL << width) - 1) << shift;
        m_steamid.m_unAll64Bits = (m_steamid.m_unAll64Bits & ~mask) | ((value << shift) & mask);
    }

    private ulong bits(uint shift, uint width) const @safe pure nothrow @nogc
    {
        return (m_steamid.m_unAll64Bits >> shift) & ((1UL << width) - 1);
    }

    /// Sets the account ID, universe and type; the instance becomes 0 for
    /// clans and game servers and `k_unSteamUserDefaultInstance` otherwise.
    void Set(uint unAccountID, EUniverse eUniverse, EAccountType eAccountType) @safe pure nothrow @nogc
    {
        const instance = eAccountType == EAccountType.k_EAccountTypeClan
            || eAccountType == EAccountType.k_EAccountTypeGameServer ? 0 : k_unSteamUserDefaultInstance;
        InstancedSet(unAccountID, instance, eUniverse, eAccountType);
    }

    /// Sets all four components.
    void InstancedSet(uint unAccountID, uint unInstance, EUniverse eUniverse, EAccountType eAccountType) @safe pure nothrow @nogc
    {
        SetAccountID(unAccountID);
        SetAccountInstance(unInstance);
        SetEUniverse(eUniverse);
        setBits(52, 4, eAccountType);
    }

    /// Sets the account ID and instance from the low 52 bits of `ulIdentifier`.
    void FullSet(ulong ulIdentifier, EUniverse eUniverse, EAccountType eAccountType) @safe pure nothrow @nogc
    {
        InstancedSet(cast(uint)(ulIdentifier & k_unSteamAccountIDMask),
                cast(uint)((ulIdentifier >> 32) & k_unSteamAccountInstanceMask), eUniverse, eAccountType);
    }

    /// Sets from the 64-bit representation.
    void SetFromUint64(ulong ulSteamID) @safe pure nothrow @nogc
    {
        m_steamid.m_unAll64Bits = ulSteamID;
    }

    /// Resets to the invalid ID.
    void Clear() @safe pure nothrow @nogc
    {
        m_steamid.m_unAll64Bits = 0;
    }

    /// The 64-bit representation.
    ulong ConvertToUint64() const @safe pure nothrow @nogc
    {
        return m_steamid.m_unAll64Bits;
    }

    /// Universe, type and account ID combined, without the instance.
    ulong GetStaticAccountKey() const @safe pure nothrow @nogc
    {
        return (cast(ulong) GetEUniverse() << 56) + (cast(ulong) GetEAccountType() << 52) + GetAccountID();
    }

    /// Makes a blank anonymous game server logon.
    void CreateBlankAnonLogon(EUniverse eUniverse) @safe pure nothrow @nogc
    {
        InstancedSet(0, 0, eUniverse, EAccountType.k_EAccountTypeAnonGameServer);
    }

    /// Makes a blank anonymous user logon.
    void CreateBlankAnonUserLogon(EUniverse eUniverse) @safe pure nothrow @nogc
    {
        InstancedSet(0, 0, eUniverse, EAccountType.k_EAccountTypeAnonUser);
    }

    /// Whether this is a blank anonymous account.
    bool BBlankAnonAccount() const @safe pure nothrow @nogc
    {
        return GetAccountID() == 0 && BAnonAccount() && GetUnAccountInstance() == 0;
    }

    /// Whether this is a (persistent or anonymous) game server account.
    bool BGameServerAccount() const @safe pure nothrow @nogc
    {
        return GetEAccountType() == EAccountType.k_EAccountTypeGameServer
            || GetEAccountType() == EAccountType.k_EAccountTypeAnonGameServer;
    }

    /// Whether this is a persistent game server account.
    bool BPersistentGameServerAccount() const @safe pure nothrow @nogc
    {
        return GetEAccountType() == EAccountType.k_EAccountTypeGameServer;
    }

    /// Whether this is an anonymous game server account.
    bool BAnonGameServerAccount() const @safe pure nothrow @nogc
    {
        return GetEAccountType() == EAccountType.k_EAccountTypeAnonGameServer;
    }

    /// Whether this is a content server account.
    bool BContentServerAccount() const @safe pure nothrow @nogc
    {
        return GetEAccountType() == EAccountType.k_EAccountTypeContentServer;
    }

    /// Whether this is a clan account.
    bool BClanAccount() const @safe pure nothrow @nogc
    {
        return GetEAccountType() == EAccountType.k_EAccountTypeClan;
    }

    /// Whether this is a chat account.
    bool BChatAccount() const @safe pure nothrow @nogc
    {
        return GetEAccountType() == EAccountType.k_EAccountTypeChat;
    }

    /// Whether this is a lobby.
    bool IsLobby() const @safe pure nothrow @nogc
    {
        return GetEAccountType() == EAccountType.k_EAccountTypeChat
            && (GetUnAccountInstance() & EChatSteamIDInstanceFlags.k_EChatInstanceFlagLobby) != 0;
    }

    /// Whether this is an individual (or console user) account.
    bool BIndividualAccount() const @safe pure nothrow @nogc
    {
        return GetEAccountType() == EAccountType.k_EAccountTypeIndividual
            || GetEAccountType() == EAccountType.k_EAccountTypeConsoleUser;
    }

    /// Whether this is an anonymous account.
    bool BAnonAccount() const @safe pure nothrow @nogc
    {
        return GetEAccountType() == EAccountType.k_EAccountTypeAnonUser
            || GetEAccountType() == EAccountType.k_EAccountTypeAnonGameServer;
    }

    /// Whether this is an anonymous user account.
    bool BAnonUserAccount() const @safe pure nothrow @nogc
    {
        return GetEAccountType() == EAccountType.k_EAccountTypeAnonUser;
    }

    /// Whether this is a console user account.
    bool BConsoleUserAccount() const @safe pure nothrow @nogc
    {
        return GetEAccountType() == EAccountType.k_EAccountTypeConsoleUser;
    }

    /// Sets the account ID.
    void SetAccountID(uint unAccountID) @safe pure nothrow @nogc
    {
        setBits(0, 32, unAccountID);
    }

    /// Sets the account instance.
    void SetAccountInstance(uint unInstance) @safe pure nothrow @nogc
    {
        setBits(32, 20, unInstance);
    }

    /// The account ID.
    AccountID_t GetAccountID() const @safe pure nothrow @nogc
    {
        return cast(AccountID_t) bits(0, 32);
    }

    /// The account instance.
    uint GetUnAccountInstance() const @safe pure nothrow @nogc
    {
        return cast(uint) bits(32, 20);
    }

    /// The account type.
    EAccountType GetEAccountType() const @safe pure nothrow @nogc
    {
        return cast(EAccountType) bits(52, 4);
    }

    /// The universe.
    EUniverse GetEUniverse() const @safe pure nothrow @nogc
    {
        return cast(EUniverse) bits(56, 8);
    }

    /// Sets the universe.
    void SetEUniverse(EUniverse eUniverse) @safe pure nothrow @nogc
    {
        setBits(56, 8, eUniverse);
    }

    /// Whether the ID is well formed.
    bool IsValid() const @safe pure nothrow @nogc
    {
        const type = GetEAccountType();
        const universe = GetEUniverse();
        if (type <= EAccountType.k_EAccountTypeInvalid || type >= EAccountType.k_EAccountTypeMax)
            return false;
        if (universe <= EUniverse.k_EUniverseInvalid || universe >= EUniverse.k_EUniverseMax)
            return false;
        if (type == EAccountType.k_EAccountTypeIndividual)
        {
            if (GetAccountID() == 0 || GetUnAccountInstance() != k_unSteamUserDefaultInstance)
                return false;
        }
        if (type == EAccountType.k_EAccountTypeClan)
        {
            if (GetAccountID() == 0 || GetUnAccountInstance() != 0)
                return false;
        }
        if (type == EAccountType.k_EAccountTypeGameServer)
        {
            if (GetAccountID() == 0)
                return false;
        }
        return true;
    }

    /// Compares the 64-bit representations, as the C++ operators do.
    bool opEquals(const CSteamID rhs) const @safe pure nothrow @nogc
    {
        return m_steamid.m_unAll64Bits == rhs.m_steamid.m_unAll64Bits;
    }

    /// ditto
    int opCmp(const CSteamID rhs) const @safe pure nothrow @nogc
    {
        const a = m_steamid.m_unAll64Bits, b = rhs.m_steamid.m_unAll64Bits;
        return a < b ? -1 : a > b;
    }

    /// Hash of the 64-bit representation.
    size_t toHash() const @safe pure nothrow @nogc
    {
        return cast(size_t)(m_steamid.m_unAll64Bits ^ (m_steamid.m_unAll64Bits >> 32));
    }
}

/// `k_steamIDNil`: the invalid Steam ID.
enum CSteamID k_steamIDNil = CSteamID.init;
/// `k_steamIDOutofDateGS`: game server running an out-of-date version.
enum CSteamID k_steamIDOutofDateGS = CSteamID(0, 0, EUniverse.k_EUniverseInvalid, EAccountType.k_EAccountTypeInvalid);
/// `k_steamIDLanModeGS`: game server in LAN mode.
enum CSteamID k_steamIDLanModeGS = CSteamID(0, 0, EUniverse.k_EUniversePublic, EAccountType.k_EAccountTypeInvalid);
/// `k_steamIDNotInitYetGS`: game server not yet initialized.
enum CSteamID k_steamIDNotInitYetGS = CSteamID(1, 0, EUniverse.k_EUniverseInvalid, EAccountType.k_EAccountTypeInvalid);
/// `k_steamIDNonSteamGS`: game server not connected to Steam.
enum CSteamID k_steamIDNonSteamGS = CSteamID(2, 0, EUniverse.k_EUniverseInvalid, EAccountType.k_EAccountTypeInvalid);

/// Game ID: app ID (bits 0-23), type (24-31) and mod ID (32-63).
struct CGameID
{
align(1):
    /// Kind of game a CGameID refers to.
    enum EGameIDType : int
    {
        k_EGameIDTypeApp = 0, ///
        k_EGameIDTypeGameMod = 1, ///
        k_EGameIDTypeShortcut = 2, ///
    }

    enum k_EGameIDTypeApp = EGameIDType.k_EGameIDTypeApp; /// ditto
    enum k_EGameIDTypeGameMod = EGameIDType.k_EGameIDTypeGameMod; /// ditto
    enum k_EGameIDTypeShortcut = EGameIDType.k_EGameIDTypeShortcut; /// ditto

    /// The C++ bitfield struct `GameID_t`, with accessors for its fields.
    struct GameID_t
    {
    align(1):
        private uint m_appAndType;
        /// Mod ID.
        uint m_nModID;

        /// App ID (24 bits).
        uint m_nAppID() const @safe pure nothrow @nogc
        {
            return m_appAndType & 0xFF_FFFF;
        }

        /// ditto
        void m_nAppID(uint v) @safe pure nothrow @nogc
        {
            m_appAndType = (m_appAndType & 0xFF00_0000) | (v & 0xFF_FFFF);
        }

        /// Game ID type (8 bits).
        uint m_nType() const @safe pure nothrow @nogc
        {
            return m_appAndType >> 24;
        }

        /// ditto
        void m_nType(uint v) @safe pure nothrow @nogc
        {
            m_appAndType = (m_appAndType & 0xFF_FFFF) | (v << 24);
        }
    }

    union
    {
        /// All 64 bits.
        ulong m_ulGameID;
        /// The components.
        GameID_t m_gameID;
    }

    /// Constructs from the 64-bit representation.
    this(ulong ulGameID) @safe pure nothrow @nogc
    {
        m_ulGameID = ulGameID;
    }

    /// Constructs a Steam app ID.
    this(uint nAppID) @safe pure nothrow @nogc
    {
        m_ulGameID = 0;
        m_gameID.m_nAppID = nAppID;
    }

    /// Constructs from all components.
    this(uint nAppID, uint nModID, EGameIDType nType) @safe pure nothrow @nogc
    {
        m_gameID.m_nAppID = nAppID;
        m_gameID.m_nModID = nModID;
        m_gameID.m_nType = nType;
    }

    /// Constructs an app (`nID` is the app ID) or a shortcut (`nID` is the
    /// mod ID); any other type gives zero. Use IsValid to check the result.
    this(uint nID, EGameIDType nType) @safe pure nothrow @nogc
    {
        m_ulGameID = 0;
        if (nType == k_EGameIDTypeApp)
        {
            m_gameID.m_nType = nType;
            m_gameID.m_nAppID = nID;
        }
        else if (nType == k_EGameIDTypeShortcut)
        {
            m_gameID.m_nType = nType;
            m_gameID.m_nModID = nID;
        }
    }

    /// The 64-bit representation.
    ulong ToUint64() const @safe pure nothrow @nogc
    {
        return m_ulGameID;
    }

    /// Pointer to the 64-bit representation.
    ulong* GetUint64Ptr() return @safe pure nothrow @nogc
    {
        return &m_ulGameID;
    }

    /// Sets from the 64-bit representation.
    void Set(ulong ulGameID) @safe pure nothrow @nogc
    {
        m_ulGameID = ulGameID;
    }

    /// Whether this is a mod.
    bool IsMod() const @safe pure nothrow @nogc
    {
        return m_gameID.m_nType == k_EGameIDTypeGameMod;
    }

    /// Whether this is a shortcut.
    bool IsShortcut() const @safe pure nothrow @nogc
    {
        return m_gameID.m_nType == k_EGameIDTypeShortcut;
    }

    /// Whether this is a Steam app.
    bool IsSteamApp() const @safe pure nothrow @nogc
    {
        return m_gameID.m_nType == k_EGameIDTypeApp;
    }

    /// The mod ID, or 0 for a shortcut.
    uint ModID() const @safe pure nothrow @nogc
    {
        return m_gameID.m_nType == k_EGameIDTypeShortcut ? 0 : m_gameID.m_nModID;
    }

    /// The app ID; for a shortcut, the shortcut's ID (stored in the mod ID bits).
    uint AppID() const @safe pure nothrow @nogc
    {
        return m_gameID.m_nType == k_EGameIDTypeShortcut ? m_gameID.m_nModID : m_gameID.m_nAppID;
    }

    /// Whether the ID is well formed for its type.
    bool IsValid() const @safe pure nothrow @nogc
    {
        const app = m_gameID.m_nAppID, mod = m_gameID.m_nModID;
        switch (m_gameID.m_nType)
        {
        case k_EGameIDTypeApp:
            return app != k_uAppIdInvalid;
        case k_EGameIDTypeGameMod:
            return app != k_uAppIdInvalid && (mod & 0x8000_0000) != 0;
        case k_EGameIDTypeShortcut:
            return app == k_uAppIdInvalid && (mod & 0x8000_0000) != 0 && mod >= (5000 | 0x8000_0000);
        default:
            return false;
        }
    }

    /// Resets to zero.
    void Reset() @safe pure nothrow @nogc
    {
        m_ulGameID = 0;
    }

    /// Compares the 64-bit representations, as the C++ operators do.
    bool opEquals(const CGameID rhs) const @safe pure nothrow @nogc
    {
        return m_ulGameID == rhs.m_ulGameID;
    }

    /// ditto
    int opCmp(const CGameID rhs) const @safe pure nothrow @nogc
    {
        return m_ulGameID < rhs.m_ulGameID ? -1 : m_ulGameID > rhs.m_ulGameID;
    }

    /// Hash of the 64-bit representation.
    size_t toHash() const @safe pure nothrow @nogc
    {
        return cast(size_t)(m_ulGameID ^ (m_ulGameID >> 32));
    }
}

@safe pure nothrow @nogc unittest
{
    static assert(CSteamID.sizeof == 8 && CSteamID.alignof == 1);
    static assert(CGameID.sizeof == 8 && CGameID.alignof == 1);
}

@safe pure nothrow @nogc unittest
{
    // A typical individual Steam ID: universe 1, type 1, instance 1.
    const id = CSteamID(76_561_197_960_287_930UL);
    assert(id.GetAccountID() == 22_202);
    assert(id.GetUnAccountInstance() == 1);
    assert(id.GetEAccountType() == EAccountType.k_EAccountTypeIndividual);
    assert(id.GetEUniverse() == EUniverse.k_EUniversePublic);
    assert(id.IsValid() && id.BIndividualAccount());
}

@safe pure nothrow @nogc unittest
{
    const id = CSteamID(22_202, EUniverse.k_EUniversePublic, EAccountType.k_EAccountTypeIndividual);
    assert(id.ConvertToUint64() == 76_561_197_960_287_930UL);
    const clan = CSteamID(5, EUniverse.k_EUniversePublic, EAccountType.k_EAccountTypeClan);
    assert(clan.GetUnAccountInstance() == 0 && clan.BClanAccount() && clan.IsValid());
}

@safe pure nothrow @nogc unittest
{
    CSteamID lobby;
    lobby.InstancedSet(7, EChatSteamIDInstanceFlags.k_EChatInstanceFlagLobby,
            EUniverse.k_EUniversePublic, EAccountType.k_EAccountTypeChat);
    assert(lobby.IsLobby() && lobby.BChatAccount());
    assert(!k_steamIDNil.IsValid());
    assert(k_steamIDNotInitYetGS.GetAccountID() == 1);
}

@safe pure nothrow @nogc unittest
{
    assert(CSteamID(1) < CSteamID(2));
    assert(CSteamID(3) == CSteamID(3));
}

@safe pure nothrow @nogc unittest
{
    auto g = CGameID(480);
    assert(g.AppID() == 480 && g.IsSteamApp() && g.IsValid() && g.ToUint64() == 480);
    auto mod = CGameID(480, 0x8000_0001, CGameID.k_EGameIDTypeGameMod);
    assert(mod.IsMod() && mod.ModID() == 0x8000_0001 && mod.AppID() == 480 && mod.IsValid());
    assert(mod.ToUint64() == (0x8000_0001UL << 32 | 1UL << 24 | 480));
}

@safe pure nothrow @nogc unittest
{
    // A shortcut keeps its ID in the mod ID bits; AppID returns it and ModID returns 0.
    auto shortcut = CGameID(0x8000_1389, CGameID.k_EGameIDTypeShortcut);
    assert(shortcut.IsShortcut() && shortcut.IsValid());
    assert(shortcut.AppID() == 0x8000_1389 && shortcut.ModID() == 0);
    assert(shortcut.ToUint64() == (0x8000_1389UL << 32 | 2UL << 24));
}

@safe pure nothrow @nogc unittest
{
    auto app = CGameID(480, CGameID.k_EGameIDTypeApp);
    assert(app.IsSteamApp() && app.AppID() == 480 && app.ToUint64() == 480);
}

@safe pure nothrow @nogc unittest
{
    // The two-argument constructor only handles apps and shortcuts; other types stay zero.
    assert(CGameID(480, CGameID.k_EGameIDTypeGameMod).ToUint64() == 0);
}
