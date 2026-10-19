/// Platform-dependent ABI parameters of the Steamworks headers.
module steamworks.raw.platform;

version (linux)
    private enum bool packSmall = true;
else version (OSX)
    private enum bool packSmall = true;
else version (iOS)
    private enum bool packSmall = true;
else version (TVOS)
    private enum bool packSmall = true;
else version (WatchOS)
    private enum bool packSmall = true;
else version (VisionOS)
    private enum bool packSmall = true;
else version (FreeBSD)
    private enum bool packSmall = true;
else
    private enum bool packSmall = false;

/// Whether the headers select `VALVE_CALLBACK_PACK_SMALL` (Linux, Android,
/// Apple platforms and FreeBSD) rather than `VALVE_CALLBACK_PACK_LARGE`.
enum bool VALVE_CALLBACK_PACK_SMALL = packSmall;

/// Whether the headers select `VALVE_CALLBACK_PACK_LARGE` (Windows).
enum bool VALVE_CALLBACK_PACK_LARGE = !packSmall;

/// The `#pragma pack` value callback structs are declared with: 4 for
/// `VALVE_CALLBACK_PACK_SMALL`, 8 for `VALVE_CALLBACK_PACK_LARGE`.
enum size_t VALVE_CALLBACK_PACK = packSmall ? 4 : 8;

/// Alignment a field of type `T` receives under `#pragma pack(N)`: the
/// smaller of its natural alignment and `N`.
///
/// D's `align(N)` sets a field's alignment exactly (it can raise it), whereas
/// `#pragma pack(N)` only caps it, so packed C layouts are reproduced by
/// giving every field `align(packAlign!(T, N))`.
template packAlign(T, size_t N)
{
    enum size_t packAlign = T.alignof < N ? T.alignof : N;
}

/// Alignment of a field of type `T` in a callback struct.
template callbackAlign(T)
{
    enum size_t callbackAlign = packAlign!(T, VALVE_CALLBACK_PACK);
}

/// The headers pin `ValvePackingSentinel_t` to these sizes.
unittest
{
    static struct Sentinel
    {
        align(callbackAlign!uint) uint m_u32;
        align(callbackAlign!ulong) ulong m_u64;
        align(callbackAlign!ushort) ushort m_u16;
        align(callbackAlign!double) double m_d;
    }

    static if (VALVE_CALLBACK_PACK_SMALL)
        static assert(Sentinel.sizeof == 24);
    else
        static assert(Sentinel.sizeof == 32);
}

unittest
{
    static assert(packAlign!(ubyte, 4) == 1);
    static assert(packAlign!(ulong, 4) == 4);
    static assert(packAlign!(ulong, 1) == 1);
}
