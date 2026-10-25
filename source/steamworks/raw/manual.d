/// Hand-written ABI types the generator cannot derive from steam_api.json:
/// unions, nested types, C++ classes with virtual functions, and the trivial
/// C++ inline members of the networking address types.
///
/// Like the generated types, every layout here is checked against the SDK
/// headers by tests/abi for every platform Valve ships libsteam_api for.
module steamworks.raw.manual;

import steamworks.raw.enums;
import steamworks.raw.platform : callbackAlign;
import steamworks.raw.steamid : CSteamID;
import steamworks.raw.structs : InputAnalogActionData_t, InputDigitalActionData_t, RemotePlayInputKey_t,
    RemotePlayInputMouseMotion_t, RemotePlayInputMouseWheel_t, SteamNetConnectionInfo_t;
import steamworks.raw.types;

// ---------------------------------------------------------------------------
// steamtypes.h

/// An IPv4 or IPv6 address (steamtypes.h, `#pragma pack(1)`).
struct SteamIPAddress_t
{
align(1):
    union
    {
    align(1):
        /// IPv4 address in host byte order.
        uint m_unIPv4;
        /// IPv6 address in network byte order.
        ubyte[16] m_rgubIPv6;
        /// IPv6 address as two big-endian quadwords.
        ulong[2] m_ipv6Qword;
    }

    /// Which member of the union is valid.
    ESteamIPType m_eType;

    /// Whether the address is non-zero.
    bool IsSet() const @safe pure nothrow @nogc
    {
        if (m_eType == ESteamIPType.k_ESteamIPTypeIPv4)
            return m_unIPv4 != 0;
        return m_ipv6Qword[0] != 0 || m_ipv6Qword[1] != 0;
    }

    /// The IPv4 any-address.
    static SteamIPAddress_t IPv4Any() @safe pure nothrow @nogc
    {
        SteamIPAddress_t ip;
        ip.m_eType = ESteamIPType.k_ESteamIPTypeIPv4;
        return ip;
    }

    /// The IPv6 any-address.
    static SteamIPAddress_t IPv6Any() @safe pure nothrow @nogc
    {
        SteamIPAddress_t ip;
        ip.m_eType = ESteamIPType.k_ESteamIPTypeIPv6;
        return ip;
    }

    /// 127.0.0.1.
    static SteamIPAddress_t IPv4Loopback() @safe pure nothrow @nogc
    {
        SteamIPAddress_t ip;
        ip.m_eType = ESteamIPType.k_ESteamIPTypeIPv4;
        ip.m_unIPv4 = 0x7f00_0001;
        return ip;
    }

    /// ::1.
    static SteamIPAddress_t IPv6Loopback() @safe pure nothrow @nogc
    {
        SteamIPAddress_t ip;
        ip.m_eType = ESteamIPType.k_ESteamIPTypeIPv6;
        ip.m_rgubIPv6[15] = 1;
        return ip;
    }
}

// ---------------------------------------------------------------------------
// steamnetworkingtypes.h

/// An IPv6 address and port; IPv4 is stored as an IPv4-mapped IPv6 address
/// (steamnetworkingtypes.h, `#pragma pack(1)`).
///
/// `ToString`, `ParseString`, `GetFakeIPType` and `IsFakeIP` call into the
/// library: use `SteamAPI_SteamNetworkingIPAddr_ToString` and friends.
struct SteamNetworkingIPAddr
{
align(1):
    /// Buffer size needed by `SteamAPI_SteamNetworkingIPAddr_ToString`.
    enum int k_cchMaxString = 48;

    /// Layout of an IPv4-mapped address (`::ffff:a.b.c.d`).
    struct IPv4MappedAddress
    {
    align(1):
        /// Zero.
        ulong m_8zeros;
        /// Zero.
        ushort m_0000;
        /// 0xffff.
        ushort m_ffff;
        /// The IPv4 address in network byte order.
        ubyte[4] m_ip;
    }

    union
    {
    align(1):
        /// The address in network byte order.
        ubyte[16] m_ipv6;
        /// The address viewed as IPv4-mapped.
        IPv4MappedAddress m_ipv4;
    }

    /// Port in host byte order.
    ushort m_port;

    /// Sets everything to zero (`[::]:0`).
    void Clear() @safe pure nothrow @nogc
    {
        this = SteamNetworkingIPAddr.init;
    }

    /// Whether the address is `::` (the port is not checked).
    bool IsIPv6AllZeros() const @safe pure nothrow @nogc
    {
        foreach (b; m_ipv6)
            if (b)
                return false;
        return true;
    }

    /// Sets an IPv6 address (16 bytes, network order) and port.
    void SetIPv6(const(ubyte)* ipv6, ushort nPort) @system pure nothrow @nogc
    {
        m_ipv6[] = ipv6[0 .. 16];
        m_port = nPort;
    }

    /// Sets an IPv4-mapped address; `nIP` and `nPort` are in host byte order.
    void SetIPv4(uint nIP, ushort nPort) @safe pure nothrow @nogc
    {
        m_ipv4.m_8zeros = 0;
        m_ipv4.m_0000 = 0;
        m_ipv4.m_ffff = 0xffff;
        m_ipv4.m_ip[0] = cast(ubyte)(nIP >> 24);
        m_ipv4.m_ip[1] = cast(ubyte)(nIP >> 16);
        m_ipv4.m_ip[2] = cast(ubyte)(nIP >> 8);
        m_ipv4.m_ip[3] = cast(ubyte) nIP;
        m_port = nPort;
    }

    /// Whether this is an IPv4-mapped address.
    bool IsIPv4() const @safe pure nothrow @nogc
    {
        return m_ipv4.m_8zeros == 0 && m_ipv4.m_0000 == 0 && m_ipv4.m_ffff == 0xffff;
    }

    /// The IPv4 address in host byte order, or 0 if not IPv4.
    uint GetIPv4() const @safe pure nothrow @nogc
    {
        if (!IsIPv4())
            return 0;
        return (uint(m_ipv4.m_ip[0]) << 24) | (uint(m_ipv4.m_ip[1]) << 16) | (
                uint(m_ipv4.m_ip[2]) << 8) | uint(m_ipv4.m_ip[3]);
    }

    /// Sets `::1` and the port.
    void SetIPv6LocalHost(ushort nPort = 0) @safe pure nothrow @nogc
    {
        m_ipv4.m_8zeros = 0;
        m_ipv4.m_0000 = 0;
        m_ipv4.m_ffff = 0;
        m_ipv6[12] = 0;
        m_ipv6[13] = 0;
        m_ipv6[14] = 0;
        m_ipv6[15] = 1;
        m_port = nPort;
    }

    /// Whether this is `::1` or 127.0.0.1.
    bool IsLocalHost() const @safe pure nothrow @nogc
    {
        return (m_ipv4.m_8zeros == 0 && m_ipv4.m_0000 == 0 && m_ipv4.m_ffff == 0 && m_ipv6[12] == 0
                && m_ipv6[13] == 0 && m_ipv6[14] == 0 && m_ipv6[15] == 1) || GetIPv4() == 0x7f00_0001;
    }

    /// Byte-wise equality, as the C++ operator.
    bool opEquals(const ref SteamNetworkingIPAddr x) const @safe pure nothrow @nogc
    {
        return m_ipv6 == x.m_ipv6 && m_port == x.m_port;
    }

    /// Hash consistent with `opEquals`.
    size_t toHash() const @safe pure nothrow @nogc
    {
        size_t h = m_port;
        foreach (b; m_ipv6)
            h = h * 31 + b;
        return h;
    }
}

/// The identity of a networking peer (steamnetworkingtypes.h, `#pragma pack(1)`).
///
/// `ToString`, `ParseString`, `GetFakeIPType` and `IsFakeIP` call into the
/// library: use `SteamAPI_SteamNetworkingIdentity_ToString` and friends.
struct SteamNetworkingIdentity
{
align(1):
    /// Buffer size needed by `SteamAPI_SteamNetworkingIdentity_ToString`.
    enum int k_cchMaxString = 128;
    /// Maximum generic string length, including the terminator.
    enum int k_cchMaxGenericString = 32;
    /// Maximum Xbox pairwise ID length, including the terminator.
    enum int k_cchMaxXboxPairwiseID = 33;
    /// Maximum generic byte identity length.
    enum int k_cbMaxGenericBytes = 32;

    /// Which member of the union is valid.
    ESteamNetworkingIdentityType m_eType;

    /// Number of meaningful bytes in the union.
    int m_cbSize;

    union
    {
    align(1):
        /// SteamID as a 64-bit value.
        ulong m_steamID64;
        /// PSN ID.
        ulong m_PSNID;
        /// Generic string, zero-terminated.
        char[k_cchMaxGenericString] m_szGenericString;
        /// Xbox pairwise ID, zero-terminated.
        char[k_cchMaxXboxPairwiseID] m_szXboxPairwiseID;
        /// Generic bytes.
        ubyte[k_cbMaxGenericBytes] m_genericBytes;
        /// String of an identity type this version does not know.
        char[k_cchMaxString] m_szUnknownRawString;
        /// IP address and port.
        SteamNetworkingIPAddr m_ip;
        /// Padding reserved for future identity types.
        uint[32] m_reserved;
    }

    /// Resets to the invalid identity.
    void Clear() @safe pure nothrow @nogc
    {
        this = SteamNetworkingIdentity.init;
    }

    /// Whether this is the invalid identity.
    bool IsInvalid() const @safe pure nothrow @nogc
    {
        return m_eType == ESteamNetworkingIdentityType.k_ESteamNetworkingIdentityType_Invalid;
    }

    /// Sets a SteamID.
    void SetSteamID(CSteamID steamID) @safe pure nothrow @nogc
    {
        SetSteamID64(steamID.ConvertToUint64());
    }

    /// The SteamID, or an invalid CSteamID if this is not a SteamID identity.
    CSteamID GetSteamID() const @safe pure nothrow @nogc
    {
        return CSteamID(GetSteamID64());
    }

    /// Sets a SteamID from its 64-bit value.
    void SetSteamID64(ulong steamID) @safe pure nothrow @nogc
    {
        m_eType = ESteamNetworkingIdentityType.k_ESteamNetworkingIdentityType_SteamID;
        m_cbSize = cast(int) ulong.sizeof;
        m_steamID64 = steamID;
    }

    /// The 64-bit SteamID, or 0 if this is not a SteamID identity.
    ulong GetSteamID64() const @safe pure nothrow @nogc
    {
        return m_eType == ESteamNetworkingIdentityType.k_ESteamNetworkingIdentityType_SteamID ? m_steamID64 : 0;
    }

    /// Sets an Xbox pairwise ID; returns false if the length is invalid.
    bool SetXboxPairwiseID(const(char)* pszString) @system pure nothrow @nogc
    {
        const l = cStringLength(pszString);
        if (l < 1 || l >= m_szXboxPairwiseID.length)
            return false;
        m_eType = ESteamNetworkingIdentityType.k_ESteamNetworkingIdentityType_XboxPairwiseID;
        m_cbSize = cast(int)(l + 1);
        m_szXboxPairwiseID[0 .. l + 1] = pszString[0 .. l + 1];
        return true;
    }

    /// The Xbox pairwise ID, or null.
    const(char)* GetXboxPairwiseID() const return @trusted pure nothrow @nogc
    {
        return m_eType == ESteamNetworkingIdentityType.k_ESteamNetworkingIdentityType_XboxPairwiseID
            ? m_szXboxPairwiseID.ptr : null;
    }

    /// Sets a PSN ID.
    void SetPSNID(ulong id) @safe pure nothrow @nogc
    {
        m_eType = ESteamNetworkingIdentityType.k_ESteamNetworkingIdentityType_SonyPSN;
        m_cbSize = cast(int) ulong.sizeof;
        m_PSNID = id;
    }

    /// The PSN ID, or 0.
    ulong GetPSNID() const @safe pure nothrow @nogc
    {
        return m_eType == ESteamNetworkingIdentityType.k_ESteamNetworkingIdentityType_SonyPSN ? m_PSNID : 0;
    }

    /// Sets an IP address and port.
    void SetIPAddr(const ref SteamNetworkingIPAddr addr) @safe pure nothrow @nogc
    {
        m_eType = ESteamNetworkingIdentityType.k_ESteamNetworkingIdentityType_IPAddress;
        m_cbSize = cast(int) SteamNetworkingIPAddr.sizeof;
        m_ip = addr;
    }

    /// The IP address, or null.
    const(SteamNetworkingIPAddr)* GetIPAddr() const return @trusted pure nothrow @nogc
    {
        return m_eType == ESteamNetworkingIdentityType.k_ESteamNetworkingIdentityType_IPAddress ? &m_ip : null;
    }

    /// Sets an IPv4 address and port (host byte order).
    void SetIPv4Addr(uint nIPv4, ushort nPort) @safe pure nothrow @nogc
    {
        m_eType = ESteamNetworkingIdentityType.k_ESteamNetworkingIdentityType_IPAddress;
        m_cbSize = cast(int) SteamNetworkingIPAddr.sizeof;
        m_ip.SetIPv4(nIPv4, nPort);
    }

    /// The IPv4 address, or 0.
    uint GetIPv4() const @safe pure nothrow @nogc
    {
        return m_eType == ESteamNetworkingIdentityType.k_ESteamNetworkingIdentityType_IPAddress ? m_ip.GetIPv4() : 0;
    }

    /// Sets localhost (`::1`).
    void SetLocalHost() @safe pure nothrow @nogc
    {
        m_eType = ESteamNetworkingIdentityType.k_ESteamNetworkingIdentityType_IPAddress;
        m_cbSize = cast(int) SteamNetworkingIPAddr.sizeof;
        m_ip.SetIPv6LocalHost();
    }

    /// Whether this is localhost.
    bool IsLocalHost() const @safe pure nothrow @nogc
    {
        return m_eType == ESteamNetworkingIdentityType.k_ESteamNetworkingIdentityType_IPAddress && m_ip.IsLocalHost();
    }

    /// Sets a generic string; returns false if it is too long.
    bool SetGenericString(const(char)* pszString) @system pure nothrow @nogc
    {
        const l = cStringLength(pszString);
        if (l >= m_szGenericString.length)
            return false;
        m_eType = ESteamNetworkingIdentityType.k_ESteamNetworkingIdentityType_GenericString;
        m_cbSize = cast(int)(l + 1);
        m_szGenericString[0 .. l + 1] = pszString[0 .. l + 1];
        return true;
    }

    /// The generic string, or null.
    const(char)* GetGenericString() const return @trusted pure nothrow @nogc
    {
        return m_eType == ESteamNetworkingIdentityType.k_ESteamNetworkingIdentityType_GenericString
            ? m_szGenericString.ptr : null;
    }

    /// Sets generic bytes; returns false if there are too many.
    bool SetGenericBytes(const(void)* data, size_t cbLen) @system pure nothrow @nogc
    {
        if (cbLen > m_genericBytes.length)
            return false;
        m_eType = ESteamNetworkingIdentityType.k_ESteamNetworkingIdentityType_GenericBytes;
        m_cbSize = cast(int) cbLen;
        m_genericBytes[0 .. cbLen] = (cast(const(ubyte)*) data)[0 .. cbLen];
        return true;
    }

    /// The generic bytes and their count, or null.
    const(ubyte)* GetGenericBytes(ref int cbLen) const return @trusted pure nothrow @nogc
    {
        if (m_eType != ESteamNetworkingIdentityType.k_ESteamNetworkingIdentityType_GenericBytes)
            return null;
        cbLen = m_cbSize;
        return m_genericBytes.ptr;
    }

    /// Equality of type, size and the meaningful bytes, as the C++ operator.
    bool opEquals(const ref SteamNetworkingIdentity x) const @trusted pure nothrow @nogc
    {
        if (m_eType != x.m_eType || m_cbSize != x.m_cbSize)
            return false;
        return payload == x.payload;
    }

    /// Hash consistent with `opEquals`.
    size_t toHash() const @safe pure nothrow @nogc
    {
        size_t h = m_eType * 31 + m_cbSize;
        foreach (b; payload)
            h = h * 31 + b;
        return h;
    }

    /// The `m_cbSize` meaningful bytes of the union.
    private const(ubyte)[] payload() const return @trusted pure nothrow @nogc
    {
        const n = m_cbSize < 0 ? 0 : m_cbSize > m_reserved.sizeof ? m_reserved.sizeof : m_cbSize;
        return (cast(const(ubyte)*) m_reserved.ptr)[0 .. n];
    }
}

private size_t cStringLength(const(char)* s) @system pure nothrow @nogc
{
    size_t n;
    while (s[n])
        ++n;
    return n;
}

/// A configuration value passed to the networking APIs
/// (steamnetworkingtypes.h, natural alignment).
struct SteamNetworkingConfigValue_t
{
    /// Which value is being set.
    ESteamNetworkingConfigValue m_eValue;

    /// Which member of `m_val` is valid. Zero (not the first enumerator) by
    /// default, as in C++.
    ESteamNetworkingConfigDataType m_eDataType = cast(ESteamNetworkingConfigDataType) 0;

    /// The C++ anonymous union type of `m_val`.
    union Value
    {
        int m_int32; ///
        long m_int64; ///
        float m_float; ///
        const(char)* m_string; /// Points to the caller's string; not copied.
        void* m_ptr; ///
    }

    /// The value.
    Value m_val;

    /// Sets an int32 value.
    void SetInt32(ESteamNetworkingConfigValue eVal, int data) @safe pure nothrow @nogc
    {
        m_eValue = eVal;
        m_eDataType = ESteamNetworkingConfigDataType.k_ESteamNetworkingConfig_Int32;
        m_val.m_int32 = data;
    }

    /// Sets an int64 value.
    void SetInt64(ESteamNetworkingConfigValue eVal, long data) @safe pure nothrow @nogc
    {
        m_eValue = eVal;
        m_eDataType = ESteamNetworkingConfigDataType.k_ESteamNetworkingConfig_Int64;
        m_val.m_int64 = data;
    }

    /// Sets a float value.
    void SetFloat(ESteamNetworkingConfigValue eVal, float data) @safe pure nothrow @nogc
    {
        m_eValue = eVal;
        m_eDataType = ESteamNetworkingConfigDataType.k_ESteamNetworkingConfig_Float;
        m_val.m_float = data;
    }

    /// Sets a pointer value.
    void SetPtr(ESteamNetworkingConfigValue eVal, void* data) @trusted pure nothrow @nogc
    {
        m_eValue = eVal;
        m_eDataType = ESteamNetworkingConfigDataType.k_ESteamNetworkingConfig_Ptr;
        m_val.m_ptr = data;
    }

    /// Sets a string value. Only the pointer is saved; the string is not copied.
    void SetString(ESteamNetworkingConfigValue eVal, const(char)* data) @trusted pure nothrow @nogc
    {
        m_eValue = eVal;
        m_eDataType = ESteamNetworkingConfigDataType.k_ESteamNetworkingConfig_String;
        m_val.m_string = data;
    }
}

// ---------------------------------------------------------------------------
// isteaminput.h

/// A Steam Input action event (isteaminput.h, `#pragma pack(1)`).
struct SteamInputActionEvent_t
{
align(1):
    /// Analog action payload.
    struct AnalogAction_t
    {
    align(1):
        InputAnalogActionHandle_t actionHandle; ///
        InputAnalogActionData_t analogActionData; ///
    }

    /// Digital action payload.
    struct DigitalAction_t
    {
    align(1):
        InputDigitalActionHandle_t actionHandle; ///
        InputDigitalActionData_t digitalActionData; ///
    }

    /// The controller the event comes from.
    InputHandle_t controllerHandle;

    /// Selects the valid member of the union.
    ESteamInputActionEventType eEventType;

    union
    {
    align(1):
        AnalogAction_t analogAction; ///
        DigitalAction_t digitalAction; ///
    }
}

// ---------------------------------------------------------------------------
// isteamremoteplay.h

/// A Remote Play input event (isteamremoteplay.h, VALVE_CALLBACK_PACK).
struct RemotePlayInput_t
{
    /// The Remote Play session.
    align(callbackAlign!RemotePlaySessionID_t) RemotePlaySessionID_t m_unSessionID;

    /// Selects the valid member of the union.
    align(callbackAlign!ERemotePlayInputType) ERemotePlayInputType m_eType;

    union
    {
        /// k_ERemotePlayInputMouseMotion.
        align(callbackAlign!RemotePlayInputMouseMotion_t) RemotePlayInputMouseMotion_t m_MouseMotion;
        /// k_ERemotePlayInputMouseButtonDown and Up.
        align(callbackAlign!ERemotePlayMouseButton) ERemotePlayMouseButton m_eMouseButton;
        /// k_ERemotePlayInputMouseWheel.
        align(callbackAlign!RemotePlayInputMouseWheel_t) RemotePlayInputMouseWheel_t m_MouseWheel;
        /// k_ERemotePlayInputKeyDown and Up.
        align(callbackAlign!RemotePlayInputKey_t) RemotePlayInputKey_t m_Key;
        /// Pads the struct to 64 bytes.
        align(1) char[64 - (RemotePlaySessionID_t.sizeof + ERemotePlayInputType.sizeof)] padding;
    }
}

// ---------------------------------------------------------------------------
// isteamdualsense.h

/// Trigger mask bit for L2.
enum SCE_PAD_TRIGGER_EFFECT_TRIGGER_MASK_L2 = 0x01;
/// Trigger mask bit for R2.
enum SCE_PAD_TRIGGER_EFFECT_TRIGGER_MASK_R2 = 0x02;
/// Index of the L2 command in ScePadTriggerEffectParam.command.
enum SCE_PAD_TRIGGER_EFFECT_PARAM_INDEX_FOR_L2 = 0;
/// Index of the R2 command in ScePadTriggerEffectParam.command.
enum SCE_PAD_TRIGGER_EFFECT_PARAM_INDEX_FOR_R2 = 1;
/// Number of triggers.
enum SCE_PAD_TRIGGER_EFFECT_TRIGGER_NUM = 2;
/// Number of control points for the multiple-position modes.
enum SCE_PAD_TRIGGER_EFFECT_CONTROL_POINT_NUM = 10;

/// DualSense adaptive trigger effect mode (isteamdualsense.h).
enum ScePadTriggerEffectMode : int
{
    SCE_PAD_TRIGGER_EFFECT_MODE_OFF, ///
    SCE_PAD_TRIGGER_EFFECT_MODE_FEEDBACK, ///
    SCE_PAD_TRIGGER_EFFECT_MODE_WEAPON, ///
    SCE_PAD_TRIGGER_EFFECT_MODE_VIBRATION, ///
    SCE_PAD_TRIGGER_EFFECT_MODE_MULTIPLE_POSITION_FEEDBACK, ///
    SCE_PAD_TRIGGER_EFFECT_MODE_SLOPE_FEEDBACK, ///
    SCE_PAD_TRIGGER_EFFECT_MODE_MULTIPLE_POSITION_VIBRATION, ///
}

enum SCE_PAD_TRIGGER_EFFECT_MODE_OFF = ScePadTriggerEffectMode.SCE_PAD_TRIGGER_EFFECT_MODE_OFF; /// ditto
enum SCE_PAD_TRIGGER_EFFECT_MODE_FEEDBACK = ScePadTriggerEffectMode.SCE_PAD_TRIGGER_EFFECT_MODE_FEEDBACK; /// ditto
enum SCE_PAD_TRIGGER_EFFECT_MODE_WEAPON = ScePadTriggerEffectMode.SCE_PAD_TRIGGER_EFFECT_MODE_WEAPON; /// ditto
enum SCE_PAD_TRIGGER_EFFECT_MODE_VIBRATION = ScePadTriggerEffectMode.SCE_PAD_TRIGGER_EFFECT_MODE_VIBRATION; /// ditto
enum SCE_PAD_TRIGGER_EFFECT_MODE_MULTIPLE_POSITION_FEEDBACK = ScePadTriggerEffectMode
        .SCE_PAD_TRIGGER_EFFECT_MODE_MULTIPLE_POSITION_FEEDBACK; /// ditto
enum SCE_PAD_TRIGGER_EFFECT_MODE_SLOPE_FEEDBACK = ScePadTriggerEffectMode.SCE_PAD_TRIGGER_EFFECT_MODE_SLOPE_FEEDBACK; /// ditto
enum SCE_PAD_TRIGGER_EFFECT_MODE_MULTIPLE_POSITION_VIBRATION = ScePadTriggerEffectMode
        .SCE_PAD_TRIGGER_EFFECT_MODE_MULTIPLE_POSITION_VIBRATION; /// ditto

/// Parameters of SCE_PAD_TRIGGER_EFFECT_MODE_OFF.
struct ScePadTriggerEffectOffParam
{
    ubyte[48] padding; ///
}

/// Parameters of SCE_PAD_TRIGGER_EFFECT_MODE_FEEDBACK.
struct ScePadTriggerEffectFeedbackParam
{
    ubyte position; /// Where the resistance starts (0-9).
    ubyte strength; /// Resistance strength (0-8).
    ubyte[46] padding; ///
}

/// Parameters of SCE_PAD_TRIGGER_EFFECT_MODE_WEAPON.
struct ScePadTriggerEffectWeaponParam
{
    ubyte startPosition; /// Where the stiffness starts (2-7).
    ubyte endPosition; /// Where the stiffness ends (startPosition+1-8).
    ubyte strength; /// Strength (0-8).
    ubyte[45] padding; ///
}

/// Parameters of SCE_PAD_TRIGGER_EFFECT_MODE_VIBRATION.
struct ScePadTriggerEffectVibrationParam
{
    ubyte position; /// Where vibration starts (0-9).
    ubyte amplitude; /// Amplitude (0-8).
    ubyte frequency; /// Frequency in Hz (0-255).
    ubyte[45] padding; ///
}

/// Parameters of SCE_PAD_TRIGGER_EFFECT_MODE_MULTIPLE_POSITION_FEEDBACK.
struct ScePadTriggerEffectMultiplePositionFeedbackParam
{
    ubyte[SCE_PAD_TRIGGER_EFFECT_CONTROL_POINT_NUM] strength; /// Strength per position (0-8).
    ubyte[38] padding; ///
}

/// Parameters of SCE_PAD_TRIGGER_EFFECT_MODE_SLOPE_FEEDBACK.
struct ScePadTriggerEffectSlopeFeedbackParam
{
    ubyte startPosition; ///
    ubyte endPosition; ///
    ubyte startStrength; ///
    ubyte endStrength; ///
    ubyte[44] padding; ///
}

/// Parameters of SCE_PAD_TRIGGER_EFFECT_MODE_MULTIPLE_POSITION_VIBRATION.
struct ScePadTriggerEffectMultiplePositionVibrationParam
{
    ubyte frequency; ///
    ubyte[SCE_PAD_TRIGGER_EFFECT_CONTROL_POINT_NUM] amplitude; /// Amplitude per position (0-8).
    ubyte[37] padding; ///
}

/// Mode-specific parameters.
union ScePadTriggerEffectCommandData
{
    ScePadTriggerEffectOffParam offParam; ///
    ScePadTriggerEffectFeedbackParam feedbackParam; ///
    ScePadTriggerEffectWeaponParam weaponParam; ///
    ScePadTriggerEffectVibrationParam vibrationParam; ///
    ScePadTriggerEffectMultiplePositionFeedbackParam multiplePositionFeedbackParam; ///
    ScePadTriggerEffectSlopeFeedbackParam slopeFeedbackParam; ///
    ScePadTriggerEffectMultiplePositionVibrationParam multiplePositionVibrationParam; ///
}

/// One trigger's effect.
struct ScePadTriggerEffectCommand
{
    ScePadTriggerEffectMode mode; ///
    ubyte[4] padding; ///
    ScePadTriggerEffectCommandData commandData; ///
}

/// Argument of ISteamInput::SetDualSenseTriggerEffect.
struct ScePadTriggerEffectParam
{
    ubyte triggerMask; /// SCE_PAD_TRIGGER_EFFECT_TRIGGER_MASK_xxx bits.
    ubyte[7] padding; ///
    ScePadTriggerEffectCommand[SCE_PAD_TRIGGER_EFFECT_TRIGGER_NUM] command; /// Indexed by SCE_PAD_TRIGGER_EFFECT_PARAM_INDEX_FOR_xxx.
}

// ---------------------------------------------------------------------------
// steam_api_common.h

/// Base class of objects registered with SteamAPI_RegisterCallback and
/// SteamAPI_RegisterCallResult (steam_api_common.h).
///
/// Steam calls the virtual functions while dispatching callbacks, so a D
/// subclass must be `extern (C++)`, must stay alive (and reachable by the GC)
/// while registered, and must not throw. On Windows the D compiler orders the
/// two `Run` overloads in the vtable as MSVC does.
extern (C++) abstract class CCallbackBase
{
    /// m_nCallbackFlags bit set while registered.
    enum ubyte k_ECallbackFlagsRegistered = 0x01;
    /// m_nCallbackFlags bit selecting game server callbacks.
    enum ubyte k_ECallbackFlagsGameServer = 0x02;

    /// Called with the callback struct for a callback.
    abstract void Run(void* pvParam) nothrow;

    /// Called with the result struct for a call result.
    abstract void Run(void* pvParam, bool bIOFailure, SteamAPICall_t hSteamAPICall) nothrow;

    /// The callback identifier this object is registered for.
    final int GetICallback() @safe pure nothrow @nogc
    {
        return m_iCallback;
    }

    /// Size of the callback struct, for validation by the dispatcher.
    abstract int GetCallbackSizeBytes() nothrow;

    /// k_ECallbackFlagsXxx bits.
    ubyte m_nCallbackFlags;

    /// The callback identifier (set this before registering a call result).
    int m_iCallback;
}

// ---------------------------------------------------------------------------
// Custom signaling (GameNetworkingSockets steamnetworkingcustomsignaling.h)

/// Sends signals for one connection made with
/// ISteamNetworkingSockets::ConnectP2PCustomSignaling. Implemented by the
/// application.
///
/// The SDK only forward-declares this class; the definition follows
/// steamnetworkingcustomsignaling.h from Valve's GameNetworkingSockets.
extern (C++) abstract class ISteamNetworkingConnectionSignaling
{
    /// Sends a signal to the peer; returns false on immediate failure.
    abstract bool SendSignal(HSteamNetConnection hConn, ref const(SteamNetConnectionInfo_t) info,
            const(void)* pMsg, int cbMsg) nothrow;

    /// Called when the connection no longer needs the object.
    abstract void Release() nothrow;
}

/// Context for ISteamNetworkingSockets::ReceivedP2PCustomSignal. Implemented
/// by the application.
///
/// The SDK only forward-declares this class; the definition follows
/// steamnetworkingcustomsignaling.h from Valve's GameNetworkingSockets.
extern (C++) abstract class ISteamNetworkingSignalingRecvContext
{
    /// A peer wants to connect: return a signaling object to accept, or null.
    abstract ISteamNetworkingConnectionSignaling OnConnectRequest(HSteamNetConnection hConn,
            ref const(SteamNetworkingIdentity) identityPeer, int nLocalVirtualPort) nothrow;

    /// Sends a rejection signal to a peer.
    abstract void SendRejectionSignal(ref const(SteamNetworkingIdentity) identityPeer, const(void)* pMsg, int cbMsg) nothrow;
}

// ---------------------------------------------------------------------------

@safe pure nothrow @nogc unittest
{
    static assert(SteamIPAddress_t.sizeof == 20 && SteamIPAddress_t.alignof == 1);
    static assert(SteamNetworkingIPAddr.sizeof == 18 && SteamNetworkingIPAddr.alignof == 1);
    static assert(SteamNetworkingIdentity.sizeof == 136 && SteamNetworkingIdentity.alignof == 1);
    static assert(ScePadTriggerEffectParam.sizeof == 120);
    static assert(RemotePlayInput_t.sizeof == 64);
}

unittest
{
    // The C++ compiler places the overloads in this vtable order.
    alias runs = __traits(getOverloads, CCallbackBase, "Run");
    version (Windows)
    {
        static assert(__traits(getVirtualIndex, runs[1]) == 0);
        static assert(__traits(getVirtualIndex, runs[0]) == 1);
    }
    else
    {
        static assert(__traits(getVirtualIndex, runs[0]) == 0);
        static assert(__traits(getVirtualIndex, runs[1]) == 1);
    }
    static assert(__traits(getVirtualIndex, CCallbackBase.GetCallbackSizeBytes) == 2);
}

@safe pure nothrow @nogc unittest
{
    SteamNetworkingIPAddr a;
    a.SetIPv4(0x7f00_0001, 27_015);
    assert(a.IsIPv4() && a.GetIPv4() == 0x7f00_0001 && a.m_port == 27_015);
    assert(a.IsLocalHost());
    static immutable ubyte[6] tail = [0xff, 0xff, 127, 0, 0, 1];
    assert(a.m_ipv6[10 .. 16] == tail);
}

@safe pure nothrow @nogc unittest
{
    SteamNetworkingIPAddr a;
    assert(a.IsIPv6AllZeros());
    a.SetIPv6LocalHost(5);
    assert(a.IsLocalHost() && !a.IsIPv4() && a.m_port == 5);
    a.Clear();
    assert(a.IsIPv6AllZeros() && a.m_port == 0);
}

@safe pure nothrow @nogc unittest
{
    SteamNetworkingIdentity id;
    assert(id.IsInvalid());
    id.SetSteamID64(76_561_197_960_287_930UL);
    assert(id.GetSteamID64() == 76_561_197_960_287_930UL && id.m_cbSize == 8);
    assert(id.GetSteamID().GetAccountID() == 22_202);
    assert(id.GetPSNID() == 0);
}

@system pure nothrow @nogc unittest
{
    SteamNetworkingIdentity a, b;
    assert(a.SetGenericString("hello"));
    assert(b.SetGenericString("hello"));
    assert(a == b && a.m_cbSize == 6);
    assert(a.GetGenericString()[0 .. 5] == "hello");
    assert(!a.SetGenericString("this string is far too long for a generic identity"));
    b.SetLocalHost();
    assert(a != b && b.IsLocalHost());
}

@safe pure nothrow @nogc unittest
{
    SteamNetworkingConfigValue_t v;
    v.SetInt32(ESteamNetworkingConfigValue.k_ESteamNetworkingConfig_TimeoutInitial, 5000);
    assert(v.m_eDataType == ESteamNetworkingConfigDataType.k_ESteamNetworkingConfig_Int32);
    assert(v.m_val.m_int32 == 5000);
    v.SetFloat(ESteamNetworkingConfigValue.k_ESteamNetworkingConfig_FakePacketLoss_Send, 0.5f);
    assert(v.m_val.m_float == 0.5f);
}

@system pure nothrow @nogc unittest
{
    SteamNetworkingConfigValue_t v;
    v.SetString(ESteamNetworkingConfigValue.k_ESteamNetworkingConfig_SDRClient_DevTicket, "ticket");
    assert(v.m_eDataType == ESteamNetworkingConfigDataType.k_ESteamNetworkingConfig_String);
    assert(v.m_val.m_string[0 .. 6] == "ticket");
}

@safe pure nothrow @nogc unittest
{
    auto ip = SteamIPAddress_t.IPv4Loopback();
    assert(ip.IsSet() && ip.m_unIPv4 == 0x7f00_0001);
    assert(!SteamIPAddress_t.IPv6Any().IsSet());
    assert(SteamIPAddress_t.IPv6Loopback().IsSet());
}
