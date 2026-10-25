/// Conversions between D strings and the NUL-terminated strings of the flat API.
///
/// Strings the API returns are owned by Steam and usually stay valid only
/// until the next call that returns a string from the same interface, so
/// `fromCString` borrows them for immediate use and `idupCString` copies them.
/// `tempCString` turns a D string into a temporary C string without the GC.
module steamworks.strings;

import core.stdc.stdlib : free, malloc;
import core.stdc.string : memcpy, strlen;

/// Borrows a NUL-terminated string as a D slice, without copying. A null
/// pointer gives an empty slice.
inout(char)[] fromCString(return scope inout(char)* s) @system pure nothrow @nogc
{
    return s is null ? null : s[0 .. strlen(s)];
}

/// Borrows the text of a fixed-size character buffer, such as `SteamErrMsg`
/// or a `char[N]` struct field: everything before the first NUL, or the whole
/// buffer when it holds none.
inout(char)[] fromCString(size_t N)(return ref inout(char)[N] buffer) @safe pure nothrow @nogc
{
    return fromCString(buffer[]);
}

/// ditto
inout(char)[] fromCString(return scope inout(char)[] buffer) @safe pure nothrow @nogc
{
    foreach (i, c; buffer)
        if (c == '\0')
            return buffer[0 .. i];
    return buffer;
}

/// Copies a NUL-terminated string into a new GC-allocated D string. A null
/// pointer gives `null`.
string idupCString(scope const(char)* s) @system pure nothrow
{
    return s is null ? null : s[0 .. strlen(s)].idup;
}

/// A temporary NUL-terminated copy of a D string, for passing to the flat API
/// without allocating from the GC. Strings shorter than `inlineCapacity`
/// characters live inside the struct; longer ones are allocated with `malloc`
/// and freed by the destructor. Obtain one with `tempCString`.
struct TempCString
{
    /// Characters (excluding the terminator) stored without allocating.
    enum size_t inlineCapacity = 255;

    private char[inlineCapacity + 1] inline_ = void;
    private char* heap;
    private size_t length_;
    private bool valid;

    @disable this(this);

    private this(scope const(char)[] s) @trusted nothrow @nogc
    {
        char* dst = inline_.ptr;
        if (s.length > inlineCapacity)
        {
            heap = cast(char*) malloc(s.length + 1);
            if (heap is null)
                return;
            dst = heap;
        }
        if (s.length)
            memcpy(dst, s.ptr, s.length);
        dst[s.length] = '\0';
        length_ = s.length;
        valid = true;
    }

    ~this() @trusted nothrow @nogc
    {
        free(heap);
    }

    /// The NUL-terminated string. Valid while this struct is alive and not
    /// moved; null only if a long string could not be allocated.
    const(char)* ptr() const return @trusted nothrow @nogc
    {
        if (!valid)
            return null;
        return heap ? heap : inline_.ptr;
    }

    /// The string without its terminator.
    const(char)[] slice() const return @trusted nothrow @nogc
    {
        return valid ? ptr[0 .. length_] : null;
    }
}

/// Makes a temporary NUL-terminated copy of `s` (see `TempCString`). Keep the
/// result in a local variable for as long as the pointer is used:
/// ---
/// auto name = tempCString(leaderboardName);
/// SteamAPI_ISteamUserStats_FindLeaderboard(SteamUserStats(), name.ptr);
/// ---
TempCString tempCString(scope const(char)[] s) @safe nothrow @nogc
{
    return TempCString(s);
}

unittest
{
    assert(fromCString(cast(const(char)*) null).length == 0);
    assert(fromCString("abc".ptr) == "abc");
}

unittest
{
    char[8] buf = "hi\0junk\0";
    assert(fromCString(buf) == "hi");
    char[3] full = "abc";
    assert(fromCString(full) == "abc");
}

unittest
{
    assert(idupCString(null) is null);
    char[4] buf = "xyz\0";
    const s = idupCString(buf.ptr);
    buf[0] = 'q';
    assert(s == "xyz");
}

unittest
{
    auto t = tempCString("hello");
    assert(t.ptr[5] == '\0');
    assert(fromCString(t.ptr) == "hello");
    assert(t.slice == "hello");
}

unittest
{
    auto empty = tempCString(null);
    assert(empty.ptr !is null && *empty.ptr == '\0');
}

unittest
{
    char[1000] long_;
    long_[] = 'x';
    auto t = tempCString(long_[]);
    assert(strlen(t.ptr) == 1000);
    assert(t.slice == long_[]);
}

@nogc nothrow unittest
{
    auto t = tempCString("no gc");
    assert(fromCString(t.ptr) == "no gc");
}
