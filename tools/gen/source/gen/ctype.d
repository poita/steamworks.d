/// Parsing of the C/C++ type spellings used by steam_api.json and the SDK
/// headers, and rendering of parsed types as D or canonical C++.
module gen.ctype;

import std.algorithm : canFind, endsWith, startsWith;
import std.array : join, split;
import std.conv : to;
import std.exception : enforce;
import std.regex : ctRegex, matchFirst;
import std.string : strip;

/// A parsed C type.
struct CType
{
    /// Base type name as spelled in C (e.g. `unsigned int`, `CSteamID`,
    /// `ISteamHTMLSurface::EHTMLMouseButton`). Empty for function pointers.
    string base;
    /// Whether the base type is const-qualified.
    bool baseConst;
    /// One entry per pointer level, innermost first; `true` marks a const pointer.
    bool[] ptrs;
    /// Whether the outermost declarator is a C++ reference.
    bool isRef;
    /// Array dimensions, outermost first (e.g. `[2][16]`).
    string[] dims;
    /// Return type of a function pointer type, or null.
    CType* fnReturn;
    /// Parameter types of a function pointer type.
    CType[] fnParams;

    /// Whether this is a pointer to a function.
    bool isFunctionPointer() const @safe pure nothrow
    {
        return fnReturn !is null;
    }

    /// Whether this is exactly `void`.
    bool isVoid() const @safe pure nothrow
    {
        return base == "void" && ptrs.length == 0 && dims.length == 0 && !isFunctionPointer;
    }
}

private enum fnPtrRe = ctRegex!(`^(.*?)\(\s*\*\s*\)\s*\((.*)\)$`);
private enum arrayRe = ctRegex!(`^(.*?)\s*\[\s*([^\]]+?)\s*\]$`);

/// Parses a C type spelling such as `const char *`, `uint8 [16]`,
/// `const SteamIPAddress_t &` or `void (*)(SteamNetworkingMessage_t *)`.
CType parseCType(string spelling) @safe
{
    string s = spelling.strip;
    enforce(s.length, "empty type");

    CType t;
    if (auto m = s.matchFirst(fnPtrRe))
    {
        t.fnReturn = new CType;
        *t.fnReturn = parseCType(m[1]);
        foreach (p; splitTopLevel(m[2]))
        {
            const ps = stripParamName(p.strip);
            if (ps == "void" || ps.length == 0)
                continue;
            t.fnParams ~= parseCType(ps);
        }
        return t;
    }

    string[] dims;
    while (true)
    {
        auto m = s.matchFirst(arrayRe);
        if (!m)
            break;
        dims = m[2].strip ~ dims;
        s = m[1].strip;
    }

    // Tokenise into words and the punctuation `*` and `&`.
    string[] toks;
    string cur;
    foreach (ch; s)
    {
        if (ch == '*' || ch == '&')
        {
            if (cur.length)
                toks ~= cur;
            cur = null;
            toks ~= [ch].idup;
        }
        else if (ch == ' ' || ch == '\t')
        {
            if (cur.length)
                toks ~= cur;
            cur = null;
        }
        else
            cur ~= ch;
    }
    if (cur.length)
        toks ~= cur;

    string[] baseWords;
    size_t i;
    for (; i < toks.length && toks[i] != "*" && toks[i] != "&"; ++i)
    {
        if (toks[i] == "const")
            t.baseConst = true;
        else if (toks[i] == "struct" || toks[i] == "class" || toks[i] == "enum")
            continue;
        else
            baseWords ~= toks[i];
    }
    enforce(baseWords.length, "no base type in '" ~ spelling ~ "'");
    t.base = baseWords.join(" ");
    for (; i < toks.length; ++i)
    {
        if (toks[i] == "*")
            t.ptrs ~= false;
        else if (toks[i] == "&")
        {
            enforce(!t.isRef, "double reference in '" ~ spelling ~ "'");
            t.isRef = true;
        }
        else if (toks[i] == "const")
        {
            enforce(t.ptrs.length, "dangling const in '" ~ spelling ~ "'");
            t.ptrs[$ - 1] = true;
        }
        else
            enforce(false, "unexpected token '" ~ toks[i] ~ "' in '" ~ spelling ~ "'");
    }
    t.dims = dims;
    return t;
}

/// Splits a comma separated list at nesting depth zero.
string[] splitTopLevel(string s) @safe pure
{
    string[] parts;
    int depth;
    size_t start;
    foreach (i, ch; s)
    {
        if (ch == '(' || ch == '[' || ch == '<')
            ++depth;
        else if (ch == ')' || ch == ']' || ch == '>')
            --depth;
        else if (ch == ',' && depth == 0)
        {
            parts ~= s[start .. i];
            start = i + 1;
        }
    }
    if (s.strip.length)
        parts ~= s[start .. $];
    return parts;
}

/// Removes a trailing parameter name from a C parameter declaration inside a
/// function pointer type (`ESteamNetworkingSocketsDebugOutputType nType`).
private string stripParamName(string p) @safe
{
    static immutable typeWords = [
        "const", "unsigned", "signed", "char", "short", "int", "long", "float", "double", "void",
        "bool"
    ];
    enum nameRe = ctRegex!(`^(.*?[\s\*&])([A-Za-z_]\w*)$`);
    auto m = p.matchFirst(nameRe);
    if (!m || typeWords.canFind(m[2]))
        return p;
    // Only strip when what remains still names a type.
    foreach (w; m[1].split)
        if (w != "const" && w != "*" && w != "&")
            return m[1].strip;
    return p;
}

/// Maps C builtin and fixed-width base types to D. Steam typedef names map to
/// themselves because the bindings declare them as D aliases.
string dBase(string cbase, scope const string[string] typeMap) @safe pure
{
    if (auto p = cbase in typeMap)
        return *p;
    switch (cbase)
    {
    case "void":
        return "void";
    case "bool":
        return "bool";
    case "char":
        return "char";
    case "signed char":
        return "byte";
    case "unsigned char":
        return "ubyte";
    case "short":
        return "short";
    case "unsigned short":
        return "ushort";
    case "int":
    case "signed int":
        return "int";
    case "unsigned int":
    case "unsigned":
        return "uint";
    case "long long":
        return "long";
    case "unsigned long long":
        return "ulong";
    case "long":
    case "long int":
        return "c_long";
    case "unsigned long":
    case "unsigned long int":
        return "c_ulong";
    case "float":
        return "float";
    case "double":
        return "double";
    case "int8_t":
        return "byte";
    case "uint8_t":
        return "ubyte";
    case "int16_t":
        return "short";
    case "uint16_t":
        return "ushort";
    case "int32_t":
        return "int";
    case "uint32_t":
        return "uint";
    case "int64_t":
        return "long";
    case "uint64_t":
        return "ulong";
    case "intptr_t":
        return "ptrdiff_t";
    case "uintptr_t":
    case "size_t":
        return "size_t";
    default:
        enforce(!cbase.canFind(' '), "unmapped multi-word C type '" ~ cbase ~ "'");
        return cbase;
    }
}

/// How a type is used, which affects references and arrays.
enum Use
{
    /// A struct field: arrays stay static arrays.
    field,
    /// A function parameter: references become `ref`, arrays decay.
    param,
    /// A function return type or alias target.
    value,
}

/// Renders `t` as a D type. Types in `classTypes` are D class references, so
/// one level of C pointer is absorbed by the reference.
string toD(const CType t, scope const string[string] typeMap, Use use = Use.value,
        scope const bool[string] classTypes = null) @safe
{
    if (t.isFunctionPointer)
    {
        string[] ps;
        foreach (p; t.fnParams)
            ps ~= toD(p, typeMap, Use.param, classTypes);
        return "extern (C) " ~ toD(*t.fnReturn, typeMap, Use.value,
                classTypes) ~ " function(" ~ ps.join(", ") ~ ") nothrow";
    }
    string s = dBase(t.base, typeMap);
    const(bool)[] ptrs = t.ptrs;
    if (t.base in classTypes)
    {
        enforce(ptrs.length && !t.isRef && !t.dims.length, "class type " ~ t.base ~ " must be used through a pointer");
        // A const object pointer has no class-reference equivalent; the
        // C++ callback interfaces are never passed const.
        enforce(!t.baseConst, "const class type " ~ t.base);
        ptrs = ptrs[1 .. $];
    }
    else if (t.baseConst)
        s = "const(" ~ s ~ ")";
    foreach (c; ptrs)
    {
        s ~= "*";
        if (c)
            s = "const(" ~ s ~ ")";
    }
    if (t.dims.length)
    {
        if (use == Use.param)
        {
            // C array parameters decay to a pointer to the element type.
            foreach (d; t.dims[1 .. $])
                s ~= "[" ~ d ~ "]";
            s ~= "*";
        }
        else
            foreach_reverse (d; t.dims)
                s ~= "[" ~ d ~ "]";
    }
    if (t.isRef)
    {
        enforce(use == Use.param, "references are only supported for parameters");
        s = "ref " ~ s;
    }
    return s;
}

/// Renders `t` as a canonical C++ type, with `name` as declarator (may be empty).
string toCpp(const CType t, string name = null) @safe
{
    if (t.isFunctionPointer)
    {
        string[] ps;
        foreach (p; t.fnParams)
            ps ~= toCpp(p);
        return toCpp(*t.fnReturn) ~ " (*" ~ name ~ ")(" ~ ps.join(", ") ~ ")";
    }
    string s = (t.baseConst ? "const " : "") ~ t.base;
    foreach (c; t.ptrs)
        s ~= c ? " *const" : " *";
    if (t.isRef)
        s ~= " &";
    if (name.length)
        s ~= " " ~ name;
    foreach (d; t.dims)
        s ~= "[" ~ d ~ "]";
    return s;
}

@safe unittest
{
    const t = parseCType("const char *");
    assert(t.base == "char" && t.baseConst && t.ptrs == [false]);
    assert(toD(t, null) == "const(char)*");
}

@safe unittest
{
    const t = parseCType("uint8 [16]");
    assert(t.base == "uint8" && t.dims == ["16"]);
    assert(toD(t, null, Use.field) == "uint8[16]");
    assert(toD(t, null, Use.param) == "uint8*");
}

@safe unittest
{
    const t = parseCType("const SteamIPAddress_t &");
    assert(t.isRef && t.baseConst);
    assert(toD(t, null, Use.param) == "ref const(SteamIPAddress_t)");
}

@safe unittest
{
    const t = parseCType("SteamNetworkingMessage_t *const *");
    assert(t.ptrs == [true, false]);
    assert(toD(t, null) == "const(SteamNetworkingMessage_t*)*");
    assert(toCpp(t) == "SteamNetworkingMessage_t *const *");
}

@safe unittest
{
    const t = parseCType("void (*)(SteamNetworkingMessage_t *)");
    assert(t.isFunctionPointer);
    assert(toD(t, null) == "extern (C) void function(SteamNetworkingMessage_t*) nothrow");
    assert(toCpp(t, "fn") == "void (*fn)(SteamNetworkingMessage_t *)");
}

@safe unittest
{
    const t = parseCType("void (*)(ESteamNetworkingSocketsDebugOutputType, const char *)");
    assert(t.fnParams.length == 2);
    assert(toD(t, null) == "extern (C) void function(ESteamNetworkingSocketsDebugOutputType, const(char)*) nothrow");
}

@safe unittest
{
    const t = parseCType("unsigned long long");
    assert(t.base == "unsigned long long");
    assert(toD(t, null) == "ulong");
}

@safe unittest
{
    const t = parseCType("char const *");
    assert(t.baseConst && t.base == "char" && t.ptrs == [false]);
}

@safe unittest
{
    string[string] map = ["ISteamHTMLSurface::EHTMLMouseButton": "EHTMLMouseButton"];
    const t = parseCType("ISteamHTMLSurface::EHTMLMouseButton");
    assert(toD(t, map) == "EHTMLMouseButton");
}

@safe unittest
{
    const t = parseCType("void (*)(int, const char *)");
    assert(t.fnParams.length == 2 && t.fnParams[0].base == "int");
}

@safe unittest
{
    const t = parseCType("ISteamMatchmakingPingResponse *");
    const bool[string] classes = ["ISteamMatchmakingPingResponse": true];
    assert(toD(t, null, Use.param, classes) == "ISteamMatchmakingPingResponse");
}

@safe unittest
{
    const t = parseCType("void (*)(int iCallbackNum, const char *pszMsg)");
    assert(t.fnParams.length == 2);
    assert(t.fnParams[1].base == "char" && t.fnParams[1].ptrs == [false]);
}

@safe unittest
{
    import std.exception : assertThrown;

    assertThrown(parseCType("const SteamIPAddress_t & &"));
}
