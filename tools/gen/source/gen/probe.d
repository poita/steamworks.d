/// The ABI probe: a C++ translation unit that includes the SDK headers and
/// records, for each target, the size, alignment and field offsets of every
/// type, every enumerator and constant value, and static_asserts every flat
/// function signature and interface version string. Its results become a D
/// module of compile-time checks run for the same targets.
module gen.probe;

import std.algorithm : canFind, sort;
import std.array : array, join, replace;
import std.conv : to;
import std.exception : enforce;
import std.file : mkdirRecurse, write;
import std.format : format;
import std.path : buildPath;
import std.regex : ctRegex, matchFirst, matchAll;
import std.string : strip;

import gen.ctype;
import gen.emit : banner, dIdent;
import gen.headers;
import gen.model;

/// A clang target and the D version conditions that select it.
struct Target
{
    string clang;
    string ldc;
    string dVersion;
}

/// Targets the probe covers: every platform Valve ships libsteam_api for.
immutable Target[] targets = [
    Target("arm64-apple-macos11", "arm64-apple-macos", "OSX AArch64"),
    Target("x86_64-apple-macos10.15", "x86_64-apple-macos", "OSX X86_64"),
    Target("x86_64-pc-windows-msvc", "x86_64-windows-msvc", "Windows X86_64"),
    Target("i686-pc-windows-msvc", "i686-windows-msvc", "Windows X86"),
    Target("x86_64-linux-gnu", "x86_64-linux-gnu", "linux X86_64"),
    Target("i686-linux-gnu", "i686-linux-gnu", "linux X86"),
    Target("aarch64-linux-gnu", "aarch64-linux-gnu", "linux AArch64"),
    Target("aarch64-linux-android", "aarch64-linux-android", "Android AArch64"),
];

/// One probed quantity.
struct Entry
{
    string key;
    string cpp;
    string d;
}

private string cppQual(string dQual) @safe pure
{
    return dQual.replace(".", "::");
}

private void layoutEntries(ref Entry[] es, string cname, string dname, const string[] fields,
        bool isClass = false)
{
    if (isClass)
        es ~= Entry("sizeof " ~ cname, "sizeof(" ~ cname ~ ")",
                "__traits(classInstanceSize, " ~ dname ~ ")");
    else
    {
        es ~= Entry("sizeof " ~ cname, "sizeof(" ~ cname ~ ")", dname ~ ".sizeof");
        es ~= Entry("alignof " ~ cname, "alignof(" ~ cname ~ ")", dname ~ ".alignof");
    }
    foreach (f; fields)
        es ~= Entry("offsetof " ~ cname ~ "::" ~ f, "offsetof(" ~ cname ~ ", " ~ f ~ ")",
                dname ~ "." ~ dIdent(f) ~ ".offsetof");
}

/// Builds the probe entries from the model.
Entry[] probeEntries(const ref Model m)
{
    Entry[] es;
    // A typedef's alignment is measured as a struct member: on i686 Linux,
    // C++ alignof reports 8 for 64-bit integers that structs align to 4.
    foreach (ref t; m.typedefs)
    {
        es ~= Entry("sizeof " ~ t.name, "sizeof(" ~ t.name ~ ")", t.name ~ ".sizeof");
        es ~= Entry("member alignment " ~ t.name, "offsetof(sw_align<" ~ t.name ~ ">, t)",
                "AlignProbe!(" ~ t.name ~ ").t.offsetof");
    }
    foreach (list; [m.structs, m.callbacks])
        foreach (ref s; list)
        {
            if (s.jsonOnly)
                continue;
            string[] fs;
            foreach (ref f; s.fields)
                fs ~= f.name;
            layoutEntries(es, s.name, s.name, fs);
            if (s.callbackId >= 0)
                es ~= Entry(s.name ~ "::k_iCallback", "(long long)" ~ s.name ~ "::k_iCallback",
                        s.name ~ ".k_iCallback");
            foreach (ref k; s.consts)
                es ~= Entry(s.name ~ "::" ~ k.name, "(long long)" ~ s.name ~ "::" ~ k.name,
                        s.name ~ "." ~ k.name);
            foreach (ref e; s.enums)
                foreach (ref v; e.values)
                    es ~= Entry(s.name ~ "::" ~ v.name, "(long long)" ~ s.name ~ "::" ~ v.name,
                            s.name ~ "." ~ e.name ~ "." ~ v.name);
        }
    auto manual = m.manualProbe.keys;
    manual.sort();
    foreach (cname; manual)
        layoutEntries(es, cname, cname.replace("::", "."), m.manualProbe[cname],
                cname == "CCallbackBase");
    foreach (ref e; m.enums)
    {
        es ~= Entry("sizeof " ~ e.cname, "sizeof(" ~ e.cname ~ ")", e.name ~ ".sizeof");
        const scope_ = scopeOf(e.cname);
        // Unsigned enums compare as unsigned: MSVC keeps them int.
        const cpre = e.baseType == "uint" ? "(long long)(unsigned int)" : "(long long)";
        const dpre = e.baseType == "uint" ? "cast(uint) " : "";
        foreach (ref v; e.values)
            es ~= Entry(scope_ ~ v.name, cpre ~ scope_ ~ v.name, dpre ~ e.name ~ "." ~ v.name);
    }
    auto menums = m.manualEnumsProbe.keys;
    menums.sort();
    foreach (dname; menums)
    {
        const me = m.manualEnumsProbe[dname];
        const cscope = scopeOf(me.cpp);
        es ~= Entry("sizeof " ~ me.cpp, "sizeof(" ~ me.cpp ~ ")", dname ~ ".sizeof");
        foreach (v; me.values)
            es ~= Entry(cscope ~ v, "(long long)" ~ cscope ~ v, dname ~ "." ~ v);
    }
    foreach (ref k; m.consts)
    {
        if (k.jsonOnly)
            continue;
        if (k.type.base == "float" || k.type.base == "double")
            es ~= Entry(k.name ~ " * 1000", "(long long)(" ~ k.name ~ " * 1000)",
                    "cast(long)(" ~ k.name ~ " * 1000)");
        else
            es ~= Entry(k.name, "(long long)(" ~ k.name ~ ")", k.name);
    }
    auto mconsts = m.manualConstsProbe.keys;
    mconsts.sort();
    foreach (dname; mconsts)
        es ~= Entry(dname, "(long long)(" ~ m.manualConstsProbe[dname] ~ ")", dname);
    return es;
}

/// The C++ scope prefix of a qualified name: `CGameID::` for `CGameID::EGameIDType`.
string scopeOf(string qualified) @safe pure
{
    import std.string : lastIndexOf;

    const i = qualified.lastIndexOf("::");
    return i < 0 ? "" : qualified[0 .. i + 2];
}

/// Sentinel ending the layout table, so clang never compresses trailing zeros.
enum long sentinel = 0x5157_EA4D;

/// Emits the C++ probe.
string emitProbeCpp(const ref Model m, string sdk)
{
    auto es = probeEntries(m);
    string o = banner(sdk);
    o ~= q"CPP
// Compiled by tools/gen --abi for each target with
//   clang++ -target <triple> -std=c++17 -ffreestanding -nostdinc++ -isystem tests/abi/stub -I sdk/public -S -emit-llvm
// The layout table becomes tests/abi/source/abi_expected.d.

// Expose private members (servernetadr_t, gameserveritem_t, CSteamID) to
// offsetof, and the optional declarations of steam_api.h.
#define private public
#define protected public
#define VERSION_SAFE_STEAM_API_INTERFACES
#define USE_BREAKPAD_HANDLER
#include "steam/steam_api_flat.h"
#include "steam/steam_gameserver.h"
#include "steam/isteamdualsense.h"
#include "steam/steamnetworkingfakeip.h"
#include "steam/isteamappticket.h"
#include "steam/isteamgamecoordinator.h"
#undef private
#undef protected

template <class T> struct sw_align { char c; T t; };
template <class A, class B> struct sw_same { static constexpr bool value = false; };
template <class A> struct sw_same<A, A> { static constexpr bool value = true; };
constexpr bool sw_streq(const char *a, const char *b) { return *a == *b && (*a == 0 || sw_streq(a + 1, b + 1)); }

CPP";
    o ~= "\n// SteamInterface version strings.\n";
    auto macros = m.headers.versionMacros.keys;
    macros.sort();
    foreach (k; macros)
        o ~= format!"static_assert(sw_streq(%s, \"%s\"), \"%s\");\n"(k, m.headers.versionMacros[k], k);
    o ~= "\n// Flat function signatures, as the bindings declare them.\n";
    foreach (ref f; m.allFunctions)
    {
        string[] ps;
        foreach (ref p; f.params)
            ps ~= toCpp(p.type);
        o ~= format!"static_assert(sw_same<decltype(&%s), %s (*)(%s)>::value, \"%s\");\n"(f.name,
                toCpp(f.ret), ps.join(", "), f.name);
    }
    o ~= "\n// Layout, enumerator and constant values.\n";
    o ~= "extern \"C\" const long long steamworks_layout[] = {\n";
    foreach (ref e; es)
        o ~= "    (long long)(" ~ e.cpp ~ "), // " ~ e.key ~ "\n";
    o ~= format!"    %sLL\n};\n"(sentinel);
    return o;
}

/// Runs clang for every target and emits the D expectations module.
string runProbe(const ref Model m, string sdk, string clang, string includeDir, string abiDir)
{
    import std.process : execute;

    auto es = probeEntries(m);
    const stub = buildPath(abiDir, "stub");
    mkdirRecurse(stub);
    write(buildPath(stub, "string.h"), "#pragma once\n#include <stddef.h>\n"
            ~ "void *memset(void *, int, size_t);\nvoid *memcpy(void *, const void *, size_t);\n"
            ~ "int memcmp(const void *, const void *, size_t);\nsize_t strlen(const char *);\n"
            ~ "char *strncpy(char *, const char *, size_t);\n");
    write(buildPath(stub, "stdio.h"), "#pragma once\n#include <stddef.h>\n"
            ~ "int snprintf(char *, size_t, const char *, ...);\n");
    const probe = buildPath(abiDir, "probe.cpp");
    write(probe, emitProbeCpp(m, sdk));

    long[][] results;
    foreach (t; targets)
    {
        auto r = execute([
            clang, "-target", t.clang, "-std=c++17", "-ffreestanding", "-nostdinc++",
            "-isystem", stub, "-I", includeDir, "-S", "-emit-llvm", "-o", "-", probe
        ]);
        enforce(r.status == 0, "clang failed for " ~ t.clang ~ ":\n" ~ r.output);
        results ~= parseLayout(r.output, es.length + 1, t.clang);
        enforce(results[$ - 1][$ - 1] == sentinel, "probe sentinel mismatch for " ~ t.clang);
    }

    string o = banner(sdk);
    o ~= q"D

/// ABI expectations measured by compiling tests/abi/probe.cpp with clang for
/// every target. Compiling this module checks, at compile time, that the D
/// bindings reproduce each size, alignment, offset and value.
module abi_expected;

import steamworks.raw;

/// Places a `T` after a `char`; its offset is `T`'s alignment as a member.
struct AlignProbe(T)
{
    char c;
    T t;
}

D";
    // One entry per line; dfmt would take minutes to re-wrap the tables.
    o ~= "\n// dfmt off\nversion (Android)\n{\n";
    o ~= "    version (AArch64) enum abiTarget = \"aarch64-linux-android\";\n}\n";
    o ~= "else version (OSX)\n{\n    version (AArch64) enum abiTarget = \"arm64-apple-macos\";\n"
        ~ "    else version (X86_64) enum abiTarget = \"x86_64-apple-macos\";\n}\n";
    o ~= "else version (Windows)\n{\n    version (X86_64) enum abiTarget = \"x86_64-windows-msvc\";\n"
        ~ "    else version (X86) enum abiTarget = \"i686-windows-msvc\";\n}\n";
    o ~= "else version (linux)\n{\n    version (X86_64) enum abiTarget = \"x86_64-linux-gnu\";\n"
        ~ "    else version (X86) enum abiTarget = \"i686-linux-gnu\";\n"
        ~ "    else version (AArch64) enum abiTarget = \"aarch64-linux-gnu\";\n}\n\n";
    o ~= "/// Whether expectations exist for the target being compiled.\n";
    o ~= "enum bool haveAbiExpectations = is(typeof(abiTarget));\n\n";
    o ~= format!"/// Number of probed quantities.\nenum size_t abiEntryCount = %s;\n\n"(es.length);
    o ~= "/// What each entry measures.\nimmutable string[abiEntryCount] abiKeys = [\n";
    foreach (ref e; es)
        o ~= "    \"" ~ e.key ~ "\",\n";
    o ~= "];\n\n";
    o ~= "/// The D side of each entry.\nenum long[abiEntryCount] abiActual = [\n";
    foreach (ref e; es)
        o ~= "    cast(long)(" ~ e.d ~ "),\n";
    o ~= "];\n\n";
    o ~= "static if (haveAbiExpectations)\n{\n";
    foreach (ti, t; targets)
    {
        o ~= (ti ? "    else " : "    ") ~ format!"static if (abiTarget == \"%s\")\n"(t.ldc);
        o ~= "        enum long[abiEntryCount] abiExpected = [";
        foreach (i, v; results[ti][0 .. $ - 1])
            o ~= (i % 16 == 0 ? "\n            " : " ") ~ v.to!string ~ ",";
        o ~= "\n        ];\n";
    }
    o ~= q"D

    /// Lists every entry where D and C++ disagree.
    string abiMismatches()
    {
        import std.conv : to;

        string r;
        foreach (i; 0 .. abiEntryCount)
            if (abiActual[i] != abiExpected[i])
                r ~= "\n  " ~ abiKeys[i] ~ ": D " ~ abiActual[i].to!string ~ ", C++ "
                    ~ abiExpected[i].to!string;
        return r;
    }

    static assert(abiMismatches().length == 0, "ABI mismatches for " ~ abiTarget ~ ":" ~ abiMismatches());
}
// dfmt on
D";
    return o;
}

/// Extracts the `steamworks_layout` array from LLVM IR.
long[] parseLayout(string ir, size_t expected, string target)
{
    auto mm = ir.matchFirst(ctRegex!(`@steamworks_layout = [^\[]*\[(\d+) x i64\] \[([^\]]*)\]`));
    enforce(mm, "steamworks_layout not found in IR for " ~ target);
    long[] vals;
    foreach (c; mm[2].matchAll(ctRegex!(`i64 (-?\d+)`)))
        vals ~= c[1].to!long;
    enforce(vals.length == expected, format!"%s: expected %s layout values, got %s"(target,
            expected, vals.length));
    return vals;
}

unittest
{
    const ir = `@steamworks_layout = dso_local constant [3 x i64] [i64 8, i64 -1, i64 1364716109], align 16`;
    assert(parseLayout(ir, 3, "t") == [8, -1, 1_364_716_109]);
}

unittest
{
    import std.algorithm : any;

    auto m = buildModel(fixtureApi, fixtureOverrides, fixtureHeaders);
    auto es = probeEntries(m);
    assert(es.any!(e => e.key == "Cb_t::k_iCallback" && e.d == "Cb_t.k_iCallback"));
    assert(es.any!(e => e.key == "offsetof Cb_t::m_id" && e.cpp == "offsetof(Cb_t, m_id)"));
    // Unsigned enums compare as unsigned on every compiler.
    assert(es.any!(e => e.key == "k_EPlatAll" && e.cpp == "(long long)(unsigned int)k_EPlatAll"));
    // Typedef alignment is measured as a struct member.
    assert(es.any!(e => e.key == "member alignment uint32" && e.d == "AlignProbe!(uint32).t.offsetof"));
}

unittest
{
    import std.algorithm : canFind;

    auto m = buildModel(fixtureApi, fixtureOverrides, fixtureHeaders);
    const cpp = emitProbeCpp(m, "test");
    assert(cpp.canFind(`static_assert(sw_streq(STEAMX_INTERFACE_VERSION, "SteamX001"), "STEAMX_INTERFACE_VERSION");`));
    assert(cpp.canFind("static_assert(sw_same<decltype(&SteamAPI_ISteamX_Find), SteamAPICall_t (*)(ISteamX *, uint64_steamid)>::value"));
    assert(cpp.canFind("1364716109LL\n};"));
}

unittest
{
    assert(scopeOf("CGameID::EGameIDType") == "CGameID::");
    assert(scopeOf("EResult") == "");
}
