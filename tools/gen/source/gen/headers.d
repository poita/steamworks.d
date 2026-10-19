/// A small scanner over the Steamworks SDK headers. It recovers the facts that
/// steam_api.json does not carry: the `#pragma pack` in effect for every
/// struct, which header defines each struct or interface, and the interface
/// version macros.
module gen.headers;

import std.algorithm : sort;
import std.array : array;
import std.exception : enforce;
import std.file : dirEntries, SpanMode;
import std.path : baseName;
import std.regex : ctRegex, matchFirst;
import std.string : lineSplitter, strip;

/// Packing in effect for a struct definition.
struct Pack
{
    /// `#pragma pack` value, or 0 for natural alignment.
    int value;
    /// Whether the value comes from the VALVE_CALLBACK_PACK_SMALL/LARGE switch
    /// (4 on Linux, macOS and FreeBSD; 8 elsewhere).
    bool callback;

    /// Natural alignment.
    enum natural = Pack(0, false);
    /// The platform dependent callback packing.
    enum callbackPack = Pack(0, true);

    string toString() const @safe pure
    {
        import std.conv : to;

        return callback ? "callback" : value == 0 ? "natural" : "pack(" ~ value.to!string ~ ")";
    }
}

/// Facts recovered from the headers.
struct HeaderInfo
{
    /// Packing per struct, keyed by C++ qualified name (`Outer::Inner`).
    Pack[string] packOf;
    /// Header file (basename) defining each struct, class or union.
    string[string] headerOf;
    /// Interface version macros: name to value.
    string[string] versionMacros;
}

/// Scans every `*.h` file in `dir` except those named in `ignored`.
HeaderInfo scanHeaders(string dir, const string[] ignored = null)
{
    import std.algorithm : canFind;

    HeaderInfo info;
    auto files = dirEntries(dir, "*.h", SpanMode.shallow).array;
    files.sort!((a, b) => a.name < b.name);
    foreach (f; files)
        if (!ignored.canFind(baseName(f.name)))
            scanHeader(baseName(f.name), asciiText(f.name), info);
    return info;
}

/// Reads a header, replacing non-ASCII bytes (the headers mix Latin-1 and
/// UTF-8 copyright signs) with `?`.
string asciiText(string path)
{
    import std.file : read;

    auto bytes = cast(ubyte[]) read(path);
    foreach (ref b; bytes)
        if (b >= 0x80)
            b = '?';
    return cast(string) bytes;
}

/// Removes `//` and `/* */` comments while keeping string literals intact.
string stripComments(string src) @safe pure
{
    string o;
    o.reserve(src.length);
    size_t i;
    while (i < src.length)
    {
        const c = src[i];
        if (c == '"' || c == '\'')
        {
            size_t j = i + 1;
            while (j < src.length && src[j] != c && src[j] != '\n')
                j += src[j] == '\\' ? 2 : 1;
            j = j < src.length ? j + 1 : j;
            o ~= src[i .. j];
            i = j;
        }
        else if (c == '/' && i + 1 < src.length && src[i + 1] == '/')
        {
            while (i < src.length && src[i] != '\n')
                ++i;
        }
        else if (c == '/' && i + 1 < src.length && src[i + 1] == '*')
        {
            i += 2;
            while (i + 1 < src.length && !(src[i] == '*' && src[i + 1] == '/'))
            {
                if (src[i] == '\n')
                    o ~= '\n';
                ++i;
            }
            i += 2;
        }
        else
        {
            o ~= c;
            ++i;
        }
    }
    return o;
}

/// Scans a single header's text, accumulating into `info`.
void scanHeader(string file, string text, ref HeaderInfo info)
{
    enum packPushRe = ctRegex!(`^\s*#\s*pragma\s+pack\s*\(\s*push\s*,\s*(\d+)\s*\)`);
    enum packPushBareRe = ctRegex!(`^\s*#\s*pragma\s+pack\s*\(\s*push\s*\)`);
    enum packSetRe = ctRegex!(`^\s*#\s*pragma\s+pack\s*\(\s*(\d+)\s*\)`);
    enum packPopRe = ctRegex!(`^\s*#\s*pragma\s+pack\s*\(\s*pop\s*\)`);
    enum cbPackIfRe = ctRegex!(`^\s*#\s*if\s+defined\s*\(\s*VALVE_CALLBACK_PACK_SMALL\s*\)`);
    enum ifRe = ctRegex!(`^\s*#\s*if`);
    enum endifRe = ctRegex!(`^\s*#\s*endif`);
    enum versionRe = ctRegex!(`^\s*#\s*define\s+(\w+_INTERFACE_VERSION\w*)\s+"([^"]*)"`);
    enum structHeadRe = ctRegex!(`^\s*(?:typedef\s+)?(?:struct|class|union)\s+(\w+)\s*(?::[^{;]*)?(\{)?\s*$`);
    enum structInlineRe = ctRegex!(`^\s*(?:typedef\s+)?(?:struct|class|union)\s+(\w+)\s*(?::[^{;]*)?\{`);
    enum callbackBeginRe = ctRegex!(`^\s*STEAM_CALLBACK_BEGIN\s*\(\s*(\w+)`);

    Pack[] stack = [Pack.natural];
    // Open braces, each tagged with the struct name it opens (or null).
    string[] scopes;
    string pending;
    int skipDepth = -1;
    int ifDepth;
    bool switchPushes;

    foreach (line; logicalLines(stripComments(text)))
    {
        if (skipDepth >= 0)
        {
            // Inside a VALVE_CALLBACK_PACK_xxx switch: skip to its #endif. A
            // switch whose branches push a packing opens a callback-pack
            // region; others (size asserts) have no effect.
            if (line.matchFirst(ifRe))
                ++ifDepth;
            else if (line.matchFirst(packPushRe))
                switchPushes = true;
            else if (line.matchFirst(endifRe))
            {
                if (ifDepth == skipDepth)
                {
                    skipDepth = -1;
                    if (switchPushes)
                        stack ~= Pack.callbackPack;
                }
                --ifDepth;
            }
            continue;
        }
        if (line.matchFirst(cbPackIfRe))
        {
            ++ifDepth;
            skipDepth = ifDepth;
            switchPushes = false;
            continue;
        }
        if (line.matchFirst(ifRe))
        {
            ++ifDepth;
            continue;
        }
        if (line.matchFirst(endifRe))
        {
            --ifDepth;
            continue;
        }
        if (auto m = line.matchFirst(packPushRe))
        {
            import std.conv : to;

            stack ~= Pack(m[1].to!int, false);
            continue;
        }
        if (line.matchFirst(packPushBareRe))
        {
            stack ~= stack[$ - 1];
            continue;
        }
        if (auto m = line.matchFirst(packSetRe))
        {
            import std.conv : to;

            stack[$ - 1] = Pack(m[1].to!int, false);
            continue;
        }
        if (line.matchFirst(packPopRe))
        {
            enforce(stack.length > 1, file ~ ": unbalanced #pragma pack(pop)");
            stack = stack[0 .. $ - 1];
            continue;
        }
        if (auto m = line.matchFirst(versionRe))
        {
            info.versionMacros[m[1]] = m[2];
            continue;
        }
        if (line.strip.length && line.strip[0] == '#')
            continue;

        if (auto m = line.matchFirst(ctRegex!(`^\s*(?:typedef\s+)?enum\s+(\w+)`)))
            if (m[1] !in info.headerOf)
                info.headerOf[m[1]] = file;

        string opened;
        if (auto m = line.matchFirst(callbackBeginRe))
        {
            record(info, file, qualify(scopes, m[1]), stack[$ - 1]);
            // The macro opens a brace that STEAM_CALLBACK_END closes.
            scopes ~= m[1];
            pending = null;
            continue;
        }
        if (line.strip == "STEAM_CALLBACK_END" || line.matchFirst(ctRegex!(`^\s*STEAM_CALLBACK_END\s*\(`)))
        {
            if (scopes.length)
                scopes = scopes[0 .. $ - 1];
            continue;
        }
        if (auto m = line.matchFirst(structInlineRe))
            opened = m[1];
        else if (auto m = line.matchFirst(structHeadRe))
        {
            pending = m[1];
            continue;
        }

        foreach (ch; line)
        {
            if (ch == '{')
            {
                string name;
                if (opened.length)
                {
                    name = opened;
                    opened = null;
                }
                else if (pending.length)
                {
                    name = pending;
                    pending = null;
                }
                if (name.length)
                    record(info, file, qualify(scopes, name), stack[$ - 1]);
                scopes ~= name;
            }
            else if (ch == '}')
            {
                if (scopes.length)
                    scopes = scopes[0 .. $ - 1];
            }
            else if (ch == ';')
                pending = null;
        }
    }
    enforce(stack.length == 1, file ~ ": unbalanced #pragma pack");
}

/// Splits source into lines, joining backslash-continued lines.
string[] logicalLines(string src) @safe pure
{
    string[] lines;
    string cur;
    foreach (l; src.lineSplitter)
    {
        if (l.length && l[$ - 1] == '\\')
        {
            cur ~= l[0 .. $ - 1] ~ " ";
            continue;
        }
        lines ~= cur ~ l;
        cur = null;
    }
    if (cur.length)
        lines ~= cur;
    return lines;
}

private string qualify(const string[] scopes, string name) @safe pure
{
    string q;
    foreach (s; scopes)
        if (s.length)
            q ~= s ~ "::";
    return q ~ name;
}

private void record(ref HeaderInfo info, string file, string name, Pack pack)
{
    // The first definition wins; later ones are C++ inline helpers or
    // alternative #ifdef branches.
    if (name !in info.packOf)
    {
        info.packOf[name] = pack;
        info.headerOf[name] = file;
    }
}

unittest
{
    HeaderInfo info;
    scanHeader("x.h", `
#if defined( VALVE_CALLBACK_PACK_SMALL )
#pragma pack( push, 4 )
#elif defined( VALVE_CALLBACK_PACK_LARGE )
#pragma pack( push, 8 )
#else
#error nope
#endif
struct A_t
{
	enum { k_iCallback = 1 };
	uint64 m_x; // trailing { comment
};
#pragma pack( pop )
#pragma pack( push, 1 )
struct B
{
	struct Inner { int x; };
	Inner m_i;
};
#pragma pack( pop )
struct C { int y; };
#if defined(VALVE_CALLBACK_PACK_SMALL)
VALVE_COMPILE_TIME_ASSERT( sizeof( C ) == 4 );
#elif defined(VALVE_CALLBACK_PACK_LARGE)
VALVE_COMPILE_TIME_ASSERT( sizeof( C ) == 4 );
#endif
struct D { int z; };
enum EThing { k_EThingA = 0 };
#define STEAMX_INTERFACE_VERSION "SteamX001"
`, info);
    assert(info.packOf["D"] == Pack.natural);
    assert(info.packOf["A_t"] == Pack.callbackPack);
    assert(info.packOf["B"] == Pack(1, false));
    assert(info.packOf["B::Inner"] == Pack(1, false));
    assert(info.packOf["C"] == Pack.natural);
    assert(info.headerOf["C"] == "x.h");
    assert(info.headerOf["EThing"] == "x.h");
    assert(info.versionMacros["STEAMX_INTERFACE_VERSION"] == "SteamX001");
}

unittest
{
    HeaderInfo info;
    scanHeader("m.h", `
#pragma pack( push, 4 )
STEAM_CALLBACK_BEGIN( Cb_t, 10 + 1 )
	STEAM_CALLBACK_MEMBER( 0, float, m_f )
STEAM_CALLBACK_END(1)
struct After {};
#pragma pack( pop )
`, info);
    assert(info.packOf["Cb_t"] == Pack(4, false));
    assert(info.packOf["After"] == Pack(4, false));
}

unittest
{
    assert(stripComments("a // b\nc /* d\ne */ f \"//x\"") == "a \nc \n f \"//x\"");
}
