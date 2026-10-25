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

version (Windows)
    private enum bool charSigned = true;
else version (OSX)
    private enum bool charSigned = true;
else version (iOS)
    private enum bool charSigned = true;
else version (TVOS)
    private enum bool charSigned = true;
else version (WatchOS)
    private enum bool charSigned = true;
else version (VisionOS)
    private enum bool charSigned = true;
else version (AArch64)
    private enum bool charSigned = false;
else version (ARM)
    private enum bool charSigned = false;
else version (PPC)
    private enum bool charSigned = false;
else version (PPC64)
    private enum bool charSigned = false;
else version (RISCV32)
    private enum bool charSigned = false;
else version (RISCV64)
    private enum bool charSigned = false;
else version (SystemZ)
    private enum bool charSigned = false;
else
    private enum bool charSigned = true;

/// C's plain `char` as an integer: `byte` where the target's `char` is
/// signed (Windows, Apple platforms, x86), `ubyte` where it is unsigned
/// (other ARM, PowerPC, RISC-V and SystemZ targets).
///
/// D's `char` is always unsigned, so a by-value C `char` parameter declared
/// as D `char` would be zero-extended where C expects sign extension. The
/// bindings use `c_char` for those parameters and keep D `char` for strings
/// and character buffers.
static if (charSigned)
    alias c_char = byte;
else
    alias c_char = ubyte;

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

unittest
{
    static assert(c_char.sizeof == 1);
    version (OSX) static assert(is(c_char == byte));
    version (Windows) static assert(is(c_char == byte));
    version (X86_64) static assert(is(c_char == byte));
    version (X86) static assert(is(c_char == byte));
}
