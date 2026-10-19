/// Compares the layout table a natively compiled and run C++ probe printed
/// (tests/abi/native/main.cpp) with the same quantities measured by this D
/// program at run time; prints every mismatch and exits 1 if there is any.
module compare;

import abi_expected : abiActual, abiEntryCount, abiKeys;
import std.conv : to;
import std.stdio : File, stderr, writefln;
import std.string : strip;

int main(string[] args)
{
    if (args.length != 2)
    {
        stderr.writefln("usage: %s <probe output>", args[0]);
        return 2;
    }
    long[] cpp;
    foreach (line; File(args[1]).byLine)
        if (line.strip.length)
            cpp ~= line.strip.to!long;
    // The C++ table ends with a sentinel.
    if (cpp.length != abiEntryCount + 1)
    {
        stderr.writefln("expected %s values, got %s", abiEntryCount + 1, cpp.length);
        return 1;
    }
    // Copied at run time so the comparison does not fold at compile time.
    const long[] d = abiActual[].dup;
    int bad;
    foreach (i; 0 .. abiEntryCount)
        if (d[i] != cpp[i])
        {
            writefln("%s: D %s, C++ %s", abiKeys[i], d[i], cpp[i]);
            ++bad;
        }
    writefln("%s of %s values match", abiEntryCount - bad, abiEntryCount);
    return bad ? 1 : 0;
}
