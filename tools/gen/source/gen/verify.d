/// Verifies the D bindings against the SDK headers from the D compiler's view
/// of the bindings rather than from the generator's model.
///
/// tests/abi/reflect/dump.d makes a D compiler describe every declaration of
/// `steamworks.raw` for one target (sizes, offsets, field types, function
/// signatures, enumerator and constant values). For the same target, clang
/// describes the SDK headers (a JSON AST plus the macro definitions). This
/// module
///  - turns every D declaration that has a C++ counterpart into a C++
///    static_assert (exact field, alias and signature types; sizes, alignments
///    and offsets; values) and compiles them against the headers with clang,
///  - checks both directions for completeness: every header declaration must
///    exist in D and every D declaration in the headers, unless the
///    `abiVerify` section of tools/gen/overrides.json justifies the exception,
///  - checks the vtable order of the extern(C++) classes, and the interface
///    version lists that SteamAPI_InitEx and SteamGameServer_InitEx pass.
module gen.verify;

import std.algorithm : any, canFind, endsWith, filter, map, sort, startsWith, among;
import std.array : array, join, replace, split;
import std.conv : to;
import std.exception : enforce;
import std.format : format;
import std.json : JSONType, JSONValue, parseJSON;
import std.string : indexOf, lastIndexOf, lineSplitter, strip;

// ---------------------------------------------------------------------------
// The headers, as clang sees them.

/// A method of a C++ record.
struct CMethod
{
    string name;
    string type;
    bool isVirtual;
    bool isPure;
    bool isStatic;
    bool isSpecial; /// constructor, destructor or conversion
}

/// A C++ struct, class or union definition.
struct CRecord
{
    string name;
    string tag;
    string[] fields;
    bool[string] bitfields;
    CMethod[] methods;
    /// Static data members and enumerators of anonymous enums, unqualified.
    string[] consts;
    /// Nested named types, unqualified.
    string[] types;
    size_t bases;

    bool isInterface() const
    {
        return methods.any!(m => m.isPure);
    }
}

/// A named C++ enum.
struct CEnum
{
    string name;
    string[] values;
}

/// A free function.
struct CFunction
{
    string name;
    bool externC;
    bool isInline;
}

/// Everything the SDK headers declare, for one target.
struct CppInventory
{
    CRecord[string] records;
    bool[string] forwardOnly;
    CEnum[string] enums;
    /// Visible qualified constant name to its kind: "macro", "var",
    /// "enumerator" (of a named enum, in `constEnum`) or "anon".
    string[string] constKind;
    string[string] constEnum;
    CFunction[string] functions;
    bool[string] typedefs;
    bool[string] templates;
    /// Object-like macros: name to replacement text.
    string[string] macros;
    /// Function-like macros.
    bool[string] macroFunctions;
    /// String literals in each inline function's body, decoded.
    string[][string] functionStrings;
    /// Initializers of floating-point constants (`const float k = 1.5f;`),
    /// which C++ cannot read in a constant expression.
    double[string] floatValues;
    /// Distinct types of each free function name (overloads have several).
    bool[string][string] functionTypes;
}

/// Whether a file name belongs to the SDK headers.
bool isSteamHeader(string file) @safe pure
{
    return file.canFind("/steam/") || file.startsWith("steam/");
}

/// Builds the inventory from clang's `-ast-dump=json` output.
CppInventory cppInventory(const ref JSONValue ast)
{
    auto w = AstWalker();
    w.visit(ast, "", false, null, false, null);
    foreach (name, _; w.inv.records)
        w.inv.forwardOnly.remove(name);
    return w.inv;
}

private struct AstWalker
{
    CppInventory inv;
    string lastFile;
    // An anonymous struct or union just defined inside a record; the field
    // declared with it names it as `decltype(Record::field)`.
    string pendingAnon;
    size_t anonCount;

    // clang prints a location's file only when it differs from the previous
    // location printed, so every node is visited in output order: its "loc"
    // (spelling, then expansion), its "range", then its children.
    void track(const ref JSONValue loc)
    {
        if (loc.type != JSONType.object)
            return;
        if (auto s = "spellingLoc" in loc.object)
            track(*s);
        if (auto e = "expansionLoc" in loc.object)
            track(*e);
        if (auto f = "file" in loc.object)
            lastFile = f.str;
    }

    static string str(const ref JSONValue n, string key)
    {
        if (auto v = key in n.object)
            return v.type == JSONType.string ? v.str : null;
        return null;
    }

    static bool flag(const ref JSONValue n, string key)
    {
        if (auto v = key in n.object)
            return v.type == JSONType.true_;
        return false;
    }

    static string qualType(const ref JSONValue n)
    {
        if (auto t = "type" in n.object)
            if (auto q = "qualType" in t.object)
                return q.str;
        return null;
    }

    void visit(const ref JSONValue n, string scope_, bool externC, CRecord* rec, bool inTemplate, string fn)
    {
        if (n.type != JSONType.object)
            return;
        if (auto l = "loc" in n.object)
            track(*l);
        const declFile = lastFile;
        if (auto r = "range" in n.object)
        {
            if (auto b = "begin" in r.object)
                track(*b);
            if (auto e = "end" in r.object)
                track(*e);
        }
        const kind = str(n, "kind");
        const name = str(n, "name");
        const steam = isSteamHeader(declFile);
        const implicit = flag(n, "isImplicit");
        string childScope = scope_;
        CRecord* childRec = rec;
        bool childExternC = externC;
        bool childTemplate = inTemplate;
        string childFn = fn;

        if (kind == "LinkageSpecDecl" && str(n, "language") == "C")
            childExternC = true;
        else if (kind.among("ClassTemplateDecl", "FunctionTemplateDecl", "TypeAliasTemplateDecl"))
        {
            if (steam && !inTemplate && scope_.length == 0)
                inv.templates[name] = true;
            childTemplate = true;
        }
        else if (inTemplate)
        {
        }
        else if (kind.among("CXXRecordDecl", "RecordDecl"))
        {
            if (implicit)
            {
            }
            else if (name.length)
            {
                const q = scope_ ~ name;
                childScope = q ~ "::";
                if (steam && flag(n, "completeDefinition"))
                {
                    if (q !in inv.records)
                        inv.records[q] = CRecord(q, str(n, "tagUsed"));
                    childRec = q in inv.records;
                    if (auto b = "bases" in n.object)
                        childRec.bases = b.array.length;
                    if (rec)
                        rec.types ~= name;
                }
                else if (steam)
                {
                    inv.forwardOnly[q] = true;
                    childRec = null;
                }
            }
            else if (rec && steam)
            {
                // Anonymous members arrive in the parent as IndirectFieldDecl;
                // an anonymous type of a named field becomes decltype(Parent::field).
                const key = format!"(anonymous %s)"(++anonCount);
                inv.records[key] = CRecord(key, str(n, "tagUsed"));
                childRec = key in inv.records;
                pendingAnon = key;
                childScope = key ~ "::";
            }
            else
                childRec = null;
        }
        else if (kind == "FieldDecl" && rec && pendingAnon.length && (implicit || !name.length))
        {
            inv.records.remove(pendingAnon);
            pendingAnon = null;
        }
        else if (kind == "FieldDecl" && rec && name.length && !implicit)
        {
            rec.fields ~= name;
            if (flag(n, "isBitfield"))
                rec.bitfields[name] = true;
            const t = qualType(n);
            if (pendingAnon.length && (t.canFind("(unnamed ") || t.canFind("(anonymous ")))
            {
                auto r = inv.records[pendingAnon];
                inv.records.remove(pendingAnon);
                r.name = "decltype(" ~ scope_ ~ name ~ ")";
                inv.records[r.name] = r;
                pendingAnon = null;
            }
        }
        else if (kind == "IndirectFieldDecl" && rec && name.length)
            rec.fields ~= name;
        else if (kind.among("CXXMethodDecl", "CXXConstructorDecl", "CXXDestructorDecl",
                "CXXConversionDecl") && rec && !implicit)
        {
            rec.methods ~= CMethod(name, qualType(n), flag(n, "virtual"), flag(n, "pure"), str(n,
                    "storageClass") == "static", kind != "CXXMethodDecl");
        }
        else if (kind == "VarDecl" && steam && !fn.length && name.length)
        {
            inv.constKind[scope_ ~ name] = "var";
            if (rec)
                rec.consts ~= name;
            if (qualType(n).canFind("float") || qualType(n).canFind("double"))
            {
                const v = literalValue(n);
                if (v == v)
                    inv.floatValues[scope_ ~ name] = v;
            }
        }
        else if (kind == "EnumDecl" && steam && !fn.length)
        {
            string q;
            if (name.length)
            {
                q = scope_ ~ name;
                inv.enums[q] = CEnum(q);
                if (rec)
                    rec.types ~= name;
            }
            const scoped = str(n, "scopedEnumTag").length > 0;
            if (auto inner = "inner" in n.object)
                foreach (ref c; inner.array)
                {
                    if (str(c, "kind") != "EnumConstantDecl")
                        continue;
                    const v = str(c, "name");
                    if (q.length)
                    {
                        inv.enums[q].values ~= v;
                        if (!scoped)
                        {
                            inv.constKind[scope_ ~ v] = "enumerator";
                            inv.constEnum[scope_ ~ v] = q;
                        }
                    }
                    else
                    {
                        inv.constKind[scope_ ~ v] = "anon";
                        if (rec)
                            rec.consts ~= v;
                    }
                }
        }
        else if (kind == "FunctionDecl" && steam && scope_.length == 0 && !fn.length && !implicit)
        {
            auto p = name in inv.functions;
            if (!p)
                inv.functions[name] = CFunction(name, externC, flag(n, "inline"));
            else
                p.isInline |= flag(n, "inline");
            inv.functionTypes[name][qualType(n)] = true;
        }
        else if (kind.among("TypedefDecl", "TypeAliasDecl") && steam && !fn.length && !implicit)
        {
            if (rec)
                rec.types ~= name;
            else if (scope_.length == 0)
                inv.typedefs[name] = true;
        }
        else if (kind == "StringLiteral" && fn.length)
            inv.functionStrings[fn] ~= decodeCString(str(n, "value"));

        if (kind == "FunctionDecl")
            childFn = name;
        else if (kind.among("CXXMethodDecl", "CXXConstructorDecl", "CXXDestructorDecl", "CXXConversionDecl"))
            childFn = scope_ ~ name;
        if (auto inner = "inner" in n.object)
            foreach (ref c; inner.array)
                visit(c, childScope, childExternC, childRec, childTemplate, childFn);
    }
}

/// The value of a variable initialized with a (possibly negated) numeric
/// literal, or NaN.
private double literalValue(const ref JSONValue n)
{
    double sign = 1;
    double walk(const ref JSONValue x)
    {
        const k = AstWalker.str(x, "kind");
        if (k.among("FloatingLiteral", "IntegerLiteral"))
            return sign * AstWalker.str(x, "value").to!double;
        if (k == "UnaryOperator" && AstWalker.str(x, "opcode") == "-")
            sign = -sign;
        else if (!k.among("ImplicitCastExpr", "ParenExpr", "VarDecl", "ConstantExpr", "CStyleCastExpr"))
            return double.nan;
        if (auto inner = "inner" in x.object)
            foreach (ref c; inner.array)
            {
                const v = walk(c);
                if (v == v)
                    return v;
            }
        return double.nan;
    }

    return walk(n);
}

/// Decodes a C string literal as clang prints it (quoted, with escapes).
string decodeCString(string lit) @safe pure
{
    if (lit.length >= 2 && lit[0] == '"' && lit[$ - 1] == '"')
        lit = lit[1 .. $ - 1];
    string o;
    for (size_t i = 0; i < lit.length; ++i)
    {
        if (lit[i] != '\\' || i + 1 == lit.length)
        {
            o ~= lit[i];
            continue;
        }
        const c = lit[++i];
        if (c >= '0' && c <= '7')
        {
            int v;
            size_t k;
            for (; k < 3 && i < lit.length && lit[i] >= '0' && lit[i] <= '7'; ++k, ++i)
                v = v * 8 + (lit[i] - '0');
            --i;
            o ~= cast(char) v;
        }
        else
            o ~= c == 'n' ? '\n' : c == 't' ? '\t' : c == 'r' ? '\r' : c;
    }
    return o;
}

unittest
{
    assert(decodeCString(`"a\000b\\c\"d"`) == "a\0b\\c\"d");
    assert(decodeCString(`"x\0"`) == "x\0");
}

/// Reads the object-like and function-like macros defined by the SDK headers
/// from `clang -E -dD` output, which interleaves `#define` lines with line
/// markers naming the file being read.
void readMacros(string preprocessed, ref CppInventory inv)
{
    string file;
    foreach (line; preprocessed.lineSplitter)
    {
        if (line.startsWith("# "))
        {
            const q1 = line.indexOf('"');
            const q2 = line.lastIndexOf('"');
            if (q1 >= 0 && q2 > q1)
                file = line[q1 + 1 .. q2];
            continue;
        }
        if (!line.startsWith("#define ") || !isSteamHeader(file))
            continue;
        const rest = line["#define ".length .. $];
        size_t i;
        while (i < rest.length && (rest[i] == '_' || (rest[i] >= 'A' && rest[i] <= 'Z')
                || (rest[i] >= 'a' && rest[i] <= 'z') || (rest[i] >= '0' && rest[i] <= '9')))
            ++i;
        const name = rest[0 .. i];
        if (i < rest.length && rest[i] == '(')
            inv.macroFunctions[name] = true;
        else
            inv.macros[name] = rest[i .. $].strip;
    }
}

unittest
{
    CppInventory inv;
    readMacros("# 1 \"sdk/public/steam/a.h\" 1\n#define A 1\n#define F(x) x\n#define G\n"
            ~ "# 3 \"/usr/include/b.h\"\n#define B 2\n", inv);
    assert(inv.macros == ["A": "1", "G": ""]);
    assert("F" in inv.macroFunctions);
}

unittest
{
    // File names are printed only when they change; the record inherits the
    // file of the previous location.
    auto ast = parseJSON(`{"kind":"TranslationUnitDecl","inner":[
        {"kind":"TypedefDecl","loc":{"file":"/x/stddef.h","line":1},"name":"size_t"},
        {"kind":"CXXRecordDecl","loc":{"spellingLoc":{"file":"<scratch space>"},"expansionLoc":{"file":"/s/steam/a.h"}},
         "name":"S","tagUsed":"struct","completeDefinition":true,"inner":[
            {"kind":"FieldDecl","loc":{"line":3},"name":"m_a","type":{"qualType":"int"}},
            {"kind":"FieldDecl","loc":{"line":4},"name":"m_b","isBitfield":true,"type":{"qualType":"int"}},
            {"kind":"CXXMethodDecl","loc":{},"name":"Run","virtual":true,"pure":true,"type":{"qualType":"void ()"}},
            {"kind":"EnumDecl","loc":{},"inner":[{"kind":"EnumConstantDecl","name":"k_iCallback"}]}]},
        {"kind":"LinkageSpecDecl","language":"C","inner":[
            {"kind":"FunctionDecl","loc":{},"name":"SteamAPI_Init"}]},
        {"kind":"EnumDecl","loc":{},"name":"EResult","inner":[{"kind":"EnumConstantDecl","name":"k_EResultOK"}]},
        {"kind":"ClassTemplateDecl","loc":{"file":"/s/steam/b.h"},"name":"CCallback","inner":[
            {"kind":"CXXRecordDecl","loc":{},"name":"CCallback","completeDefinition":true,"inner":[
                {"kind":"TypedefDecl","loc":{},"name":"func_t"}]}]},
        {"kind":"FunctionDecl","loc":{"file":"/x/string.h"},"name":"memset"}]}`);
    auto inv = cppInventory(ast);
    assert(inv.records.keys == ["S"]);
    assert(inv.records["S"].fields == ["m_a", "m_b"] && "m_b" in inv.records["S"].bitfields);
    assert(inv.records["S"].isInterface && inv.records["S"].consts == ["k_iCallback"]);
    assert(inv.constKind["S::k_iCallback"] == "anon");
    assert(inv.functions.keys == ["SteamAPI_Init"] && inv.functions["SteamAPI_Init"].externC);
    assert(inv.enums["EResult"].values == ["k_EResultOK"] && inv.constEnum["k_EResultOK"] == "EResult");
    assert("size_t" !in inv.typedefs && "func_t" !in inv.typedefs);
    assert(inv.templates.keys == ["CCallback"] && "CCallback" !in inv.records);
}

// ---------------------------------------------------------------------------
// The bindings, as the D compiler sees them.

struct DField
{
    string name;
    long offset;
    long size;
    string type;
    string visibility;
}

struct DMethod
{
    string name;
    long vindex = -1;
    bool isStatic;
    string type;
}

struct DAggregate
{
    string name; /// C++ spelling
    string kind;
    string size;
    string alignment;
    DField[] fields;
    string[] members;
    DMethod[] methods;
}

struct DEnum
{
    string name;
    string base;
    long size;
    string[] values;
    string[] numbers;
}

struct DConst
{
    string name;
    string type;
    string value;
}

struct DFunction
{
    string name;
    string linkage;
    string kind;
    string type;
}

/// The declarations of one dump.
struct DInventory
{
    string[] modules;
    DAggregate[string] aggregates;
    string[] aggregateOrder;
    DEnum[string] enums;
    DConst[] consts;
    string[string] aliases;
    DFunction[] functions;
    string[] others;
    bool complete;
}

/// Maps D names (dotted, as dump.d prints them) to C++ names. `renames` holds
/// D names whose C++ name differs by more than `.` versus `::`.
struct NameMap
{
    string[string] renames;

    string cpp(string d) const @safe pure
    {
        if (auto p = d in renames)
            return *p;
        return d.replace(".", "::");
    }

    /// Rewrites every (possibly dotted) identifier in a type expression.
    string type(string t) const @safe pure
    {
        string o;
        size_t i;
        while (i < t.length)
        {
            const c = t[i];
            if (c == '_' || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z'))
            {
                size_t j = i;
                while (j < t.length && (t[j] == '_' || t[j] == '.' || (t[j] >= 'A' && t[j] <= 'Z')
                        || (t[j] >= 'a' && t[j] <= 'z') || (t[j] >= '0' && t[j] <= '9')))
                    ++j;
                o ~= cpp(t[i .. j]);
                i = j;
            }
            else
                o ~= t[i++];
        }
        return o;
    }
}

unittest
{
    NameMap m;
    m.renames = ["EHTMLMouseButton": "ISteamHTMLSurface::EHTMLMouseButton"];
    assert(m.type("sw_fn<void, sw_p<ISteamHTMLSurface>, EHTMLMouseButton>")
            == "sw_fn<void, sw_p<ISteamHTMLSurface>, ISteamHTMLSurface::EHTMLMouseButton>");
    assert(m.type("sw_a<IPCFailure_t.EFailureType, 2>") == "sw_a<IPCFailure_t::EFailureType, 2>");
}

/// Parses the output of tests/abi/reflect/dump.d.
DInventory readDump(string text, const ref NameMap names)
{
    DInventory d;
    foreach (line; text.lineSplitter)
    {
        const f = line.split('\t');
        if (f.length == 0 || f[0].length != 1)
            continue;
        switch (f[0])
        {
        case "M":
            d.modules ~= f[1];
            break;
        case "S":
            const n = names.cpp(f[1]);
            d.aggregates[n] = DAggregate(n, f[2], f[3], f[4]);
            d.aggregateOrder ~= n;
            break;
        case "F":
            d.aggregates[names.cpp(f[1])].fields ~= DField(f[2], f[3].to!long, f[4].to!long, names.type(f[5]), f[6]);
            break;
        case "P":
            d.aggregates[names.cpp(f[1])].members ~= f[2];
            break;
        case "R":
            d.aggregates[names.cpp(f[1])].methods ~= DMethod(f[2], f[3].to!long, false, names.type(f[4]));
            break;
        case "N":
            d.aggregates[names.cpp(f[1])].methods ~= DMethod(f[2], -1, f[3] == "static", names.type(f[4]));
            break;
        case "E":
            const n = names.cpp(f[1]);
            d.enums[n] = DEnum(n, f[2], f[3].to!long);
            break;
        case "V":
            auto e = names.cpp(f[1]) in d.enums;
            e.values ~= f[2];
            e.numbers ~= f[3];
            break;
        case "K":
            const dot = f[1].lastIndexOf('.');
            const n = dot < 0 ? f[1] : names.cpp(f[1][0 .. dot]) ~ "::" ~ f[1][dot + 1 .. $];
            d.consts ~= DConst(n, names.type(f[2]), f[3]);
            break;
        case "T":
            d.aliases[f[1]] = names.type(f[2]);
            break;
        case "X":
            d.functions ~= DFunction(f[1], f[2], f[3], names.type(f[4]));
            break;
        case "G":
            d.others ~= f[1];
            break;
        case "Z":
            d.complete = true;
            break;
        default:
            break;
        }
    }
    return d;
}

unittest
{
    NameMap names;
    auto d = readDump("M\tm\nS\tA.B\tstruct\t8\t4\nF\tA.B\tm_x\t4\t4\tint\tpublic\nE\tE\tint\t4\n"
            ~ "V\tE\tk_a\t1\nK\tA.k_c\tint\t3\nX\tf\tC\tfunc\tsw_fn<void>\nZ\n", names);
    assert(d.complete && d.aggregates["A::B"].fields[0].offset == 4);
    assert(d.enums["E"].numbers == ["1"] && d.consts[0].name == "A::k_c");
    assert(d.functions[0].linkage == "C");
}

// ---------------------------------------------------------------------------
// Exceptions: header declarations without a D counterpart and the reverse.

/// A glob pattern (`*` matches any run of characters) with its justification.
struct Exception_
{
    string pattern;
    string reason;
    size_t uses;
}

/// The `abiVerify` section of overrides.json.
struct VerifyConfig
{
    Exception_[] cppOnly;
    Exception_[] dOnly;
    /// D constant name to the inline C++ function whose string literal it copies.
    string[string] interfaceVersionLists;
    /// Functions and methods whose types compare without const qualifiers.
    Exception_[] constRelaxed;
    NameMap names;
}

/// Reads the `abiVerify` section and the type renames of overrides.json.
VerifyConfig verifyConfig(const ref JSONValue overrides)
{
    VerifyConfig c;
    const v = overrides["abiVerify"];
    foreach (string k, ref r; v["cppOnly"].object)
        if (k[0] != '_')
            c.cppOnly ~= Exception_(k, r.str);
    foreach (string k, ref r; v["dOnly"].object)
        if (k[0] != '_')
            c.dOnly ~= Exception_(k, r.str);
    foreach (string k, ref r; v["interfaceVersionLists"].object)
        if (k[0] != '_')
            c.interfaceVersionLists[k] = r.str;
    foreach (string k, ref r; v["constRelaxed"].object)
        if (k[0] != '_')
            c.constRelaxed ~= Exception_(k, r.str);
    foreach (string k, ref r; v["renames"].object)
        if (k[0] != '_')
            c.names.renames[k] = r.str;
    foreach (string cpp, ref d; overrides["typeMap"].object)
        if (cpp[0] != '_' && d.str != cpp.replace("::", "."))
            c.names.renames[d.str] = cpp;
    return c;
}

bool globMatch(string pattern, string s) @safe pure
{
    if (pattern.length == 0)
        return s.length == 0;
    if (pattern[0] == '*')
    {
        foreach (i; 0 .. s.length + 1)
            if (globMatch(pattern[1 .. $], s[i .. $]))
                return true;
        return false;
    }
    return s.length && s[0] == pattern[0] && globMatch(pattern[1 .. $], s[1 .. $]);
}

unittest
{
    assert(globMatch("function Steam*", "function SteamUser"));
    assert(!globMatch("function Steam*", "functions"));
    assert(globMatch("a*b*c", "aXbYc") && !globMatch("a*b", "ab c"));
}

/// Whether `key` is excused by one of `list`, counting the use.
bool excused(Exception_[] list, string key)
{
    foreach (ref e; list)
        if (globMatch(e.pattern, key))
        {
            ++e.uses;
            return true;
        }
    return false;
}

// ---------------------------------------------------------------------------
// The comparison.

/// Static checks and helpers every generated check file starts with.
enum string checkPrelude = q"CPP
// Generated by tools/gen --verify from a description of the D bindings
// (tests/abi/reflect/dump.d). Each static_assert compares one D fact with
// the SDK headers.
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

typedef decltype(sizeof(0)) sw_size;
template <class T> using sw_p = T *;
template <class T> using sw_c = const T;
template <class T> using sw_r = T &;
template <class T, sw_size N> using sw_a = T[N];
template <class R, class... P> using sw_fn = R (*)(P...);
template <class C, class R, class... P> using sw_mfn = R (C::*)(P...);
template <class C, class R, class... P> using sw_mfnc = R (C::*)(P...) const;
template <class A, class B> struct sw_same { static constexpr bool value = false; };
template <class A> struct sw_same<A, A> { static constexpr bool value = true; };
template <class T> struct sw_unconst { using type = T; };
template <class T> struct sw_unconst<const T> { using type = T; };
template <bool B, class T, class F> struct sw_if { using type = T; };
template <class T, class F> struct sw_if<false, T, F> { using type = F; };

// sw_n<T>::type spells `long` as the `int` or `long long` of the same size
// (D's long is C's int64_t, which is `long` on LP64 platforms; druntime's
// c_long is `int` on ILP32 platforms), so types compare by ABI rather than
// by spelling. With K = false it also drops
// every const, for parameters D cannot spell exactly (`T *const *`).
template <class T, bool K = true> struct sw_n { using type = T; };
template <bool K> struct sw_n<long, K>
{
    using type = typename sw_if<sizeof(long) == sizeof(long long), long long,
        typename sw_if<sizeof(long) == sizeof(int), int, long>::type>::type;
};
template <bool K> struct sw_n<unsigned long, K>
{
    using type = typename sw_if<sizeof(long) == sizeof(long long), unsigned long long,
        typename sw_if<sizeof(long) == sizeof(int), unsigned int, unsigned long>::type>::type;
};
template <class T, bool K> struct sw_n<const T, K>
{
    using type = typename sw_if<K, const typename sw_n<T, K>::type, typename sw_n<T, K>::type>::type;
};
template <class T, bool K> struct sw_n<T *, K> { using type = typename sw_n<T, K>::type *; };
template <class T, bool K> struct sw_n<T &, K> { using type = typename sw_n<T, K>::type &; };
template <class T, sw_size N, bool K> struct sw_n<T[N], K> { using type = typename sw_n<T, K>::type[N]; };
template <class T, sw_size N, bool K> struct sw_n<const T[N], K>
{
    using type = typename sw_n<const T, K>::type[N];
};
// sw_v<T>::type spells a by-value `char` parameter or return as the `signed
// char` or `unsigned char` the target's `char` is, because the ABI extends it
// accordingly; the D side spells its own (unsigned) `char` as `unsigned char`.
template <class T> struct sw_v { using type = T; };
template <> struct sw_v<char> { using type = sw_if<(char)-1 < 0, signed char, unsigned char>::type; };
template <class T, bool K> using sw_nv = typename sw_v<typename sw_n<T, K>::type>::type;
template <class R, class... P, bool K> struct sw_n<R(P...), K>
{
    using type = sw_nv<R, K>(sw_nv<P, K>...);
};
template <class C, class R, class... P, bool K> struct sw_n<R (C::*)(P...), K>
{
    using type = sw_nv<R, K> (C::*)(sw_nv<P, K>...);
};
template <class C, class R, class... P, bool K> struct sw_n<R (C::*)(P...) const, K>
{
    using type = sw_nv<R, K> (C::*)(sw_nv<P, K>...) const;
};
template <class A, class B> using sw_eq = sw_same<typename sw_n<A>::type, typename sw_n<B>::type>;
template <class A, class B> using sw_eq_nc = sw_same<typename sw_n<A, false>::type, typename sw_n<B, false>::type>;
template <unsigned long long N, unsigned long long M>
constexpr bool sw_str(const char (&a)[N], const char (&b)[M])
{
    if (N != M)
        return false;
    for (unsigned long long i = 0; i < N; ++i)
        if (a[i] != b[i])
            return false;
    return true;
}
CPP";

/// The outcome of comparing one D dump with the headers.
struct Comparison
{
    string cpp; /// the C++ check file
    string[] problems; /// failures found without compiling
    size_t checks; /// static_asserts emitted
    size_t matched; /// declarations found on both sides
}

private string cppStringLiteral(string s) @safe pure
{
    string o = "\"";
    foreach (char c; s)
    {
        if (c == '"' || c == '\\')
            o ~= "\\" ~ c;
        else if (c < 0x20 || c >= 0x7f)
            o ~= format!"\\%03o"(cast(ubyte) c);
        else
            o ~= c;
    }
    return o ~ "\"";
}

private string decodeDumpString(string s) @safe pure
{
    string o;
    for (size_t i = 0; i < s.length; ++i)
    {
        if (s[i] == '\\' && i + 1 < s.length)
        {
            const c = s[++i];
            o ~= c == 'n' ? '\n' : c == 't' ? '\t' : c == '0' ? '\0' : c;
        }
        else
            o ~= s[i];
    }
    return o;
}

/// The vtable slots the C++ ABI of `msvc` gives the virtual methods of `r`,
/// as method index (into `r.methods`) per slot.
size_t[] vtableOrder(const ref CRecord r, bool msvc)
{
    size_t[] virt;
    foreach (i, ref m; r.methods)
        if (m.isVirtual)
            virt ~= i;
    if (!msvc)
        return virt;
    // MSVC groups overloads at the position of the first one, in reverse
    // declaration order.
    size_t[] o;
    bool[string] done;
    foreach (i; virt)
    {
        const n = r.methods[i].name;
        if (n in done)
            continue;
        done[n] = true;
        auto group = virt.filter!(j => r.methods[j].name == n).array;
        foreach_reverse (j; group)
            o ~= j;
    }
    return o;
}

unittest
{
    CRecord r;
    r.methods = [
        CMethod("Run", "void (void *)", true), CMethod("Run", "void (void *, bool)", true),
        CMethod("Size", "int ()", true), CMethod("Helper", "void ()")
    ];
    assert(vtableOrder(r, false) == [0, 1, 2]);
    assert(vtableOrder(r, true) == [1, 0, 2]);
}

/// Compares a D dump with the C++ inventory of the same target.
Comparison compare(const ref DInventory d, const ref CppInventory c, ref VerifyConfig cfg, bool msvc)
{
    Comparison r;
    string o = checkPrelude ~ "\n";
    void check(string cond, string label)
    {
        o ~= "static_assert(" ~ cond ~ ", " ~ cppStringLiteral(label) ~ ");\n";
        ++r.checks;
    }

    void cppOnly(string key)
    {
        if (!excused(cfg.cppOnly, key))
            r.problems ~= "missing in D: " ~ key;
    }

    // Compares the type of `&cppName` with the D type; overloaded names
    // select the overload by exact type instead.
    void signature(string key, string cppName, string dType, size_t overloads)
    {
        const label = "signature of " ~ key ~ ": " ~ dType;
        if (overloads > 1)
            check(format!"static_cast<%s>(&%s) != nullptr"(dType, cppName), label);
        else if (excused(cfg.constRelaxed, key))
            check(format!"sw_eq_nc<decltype(&%s), %s>::value"(cppName, dType), label ~ " (const relaxed)");
        else
            check(format!"sw_eq<decltype(&%s), %s>::value"(cppName, dType), label);
    }

    void dOnly(string key)
    {
        if (!excused(cfg.dOnly, key))
            r.problems ~= "not in the headers: " ~ key;
    }

    enforce(d.complete, "the D description is incomplete (dump.d did not finish)");

    // Aggregates.
    foreach (name; d.aggregateOrder)
    {
        const a = d.aggregates[name];
        const cr = name in c.records;
        if (!cr)
        {
            if (a.kind == "opaque" && name in c.forwardOnly)
            {
                o ~= "static_assert(sizeof(sw_p<" ~ name ~ ">) > 0, \"opaque " ~ name ~ "\");\n";
                ++r.matched;
            }
            else
                dOnly("struct " ~ name);
            continue;
        }
        ++r.matched;
        if (a.kind == "class")
        {
            check(format!"sizeof(%s) == %s"(name, a.size), "sizeof " ~ name);
            // Only extern(C++) classes share the C++ vtable and object layout.
            if (a.alignment != "C++")
                r.problems ~= format!"%s: extern(%s) class; the C++ layout needs extern(C++)"(name, a.alignment);
        }
        else if (a.kind != "opaque")
        {
            check(format!"sizeof(%s) == %s"(name, a.size), "sizeof " ~ name);
            check(format!"alignof(%s) == %s"(name, a.alignment), "alignof " ~ name);
            if (a.kind == "union" && cr.tag != "union")
                r.problems ~= name ~ ": D union, C++ " ~ cr.tag;
        }
        foreach (ref f; a.fields)
        {
            const cname = cr.fields.canFind(f.name) ? f.name : f.name.endsWith("_")
                && cr.fields.canFind(f.name[0 .. $ - 1]) ? f.name[0 .. $ - 1] : null;
            if (!cname.length || f.name in cr.bitfields)
            {
                dOnly("field " ~ name ~ "::" ~ f.name);
                continue;
            }
            const q = name ~ "::" ~ cname;
            check(format!"offsetof(%s, %s) == %s"(name, cname, f.offset), "offsetof " ~ q);
            check(format!"sizeof(%s) == %s"(q, f.size), "sizeof " ~ q);
            check(format!"sw_eq<decltype(%s), %s>::value"(q, f.type), "type of " ~ q ~ " is " ~ f.type);
        }
        foreach (fname; cr.fields)
        {
            const inD = a.fields.any!(f => f.name == fname || f.name == fname ~ "_");
            if (fname in cr.bitfields)
            {
                if (!a.members.canFind(fname) && !inD)
                    cppOnly("field " ~ name ~ "::" ~ fname);
            }
            else if (!inD)
                cppOnly("field " ~ name ~ "::" ~ fname);
        }
        foreach (t; cr.types)
            if ((name ~ "::" ~ t) !in d.aggregates && (name ~ "::" ~ t) !in d.enums
                    && !a.members.canFind(t) && !cfg.names.renames.byValue.canFind(name ~ "::" ~ t))
                cppOnly("type " ~ name ~ "::" ~ t);
        foreach (k; cr.consts)
            if (!a.members.canFind(k))
                cppOnly("constant " ~ name ~ "::" ~ k);

        // Methods.
        if (cr.isInterface && a.kind == "opaque")
        {
            foreach (ref m; cr.methods)
            {
                if (!m.isPure)
                    continue;
                const flat = "SteamAPI_" ~ name ~ "_" ~ m.name;
                if (!d.functions.any!(f => f.name == flat || f.name.startsWith(flat)))
                    cppOnly("interface-method " ~ name ~ "::" ~ m.name);
            }
            continue;
        }
        const vorder = vtableOrder(*cr, msvc);
        foreach (ref m; a.methods)
        {
            // D operators stand for the C++ ones; their signatures differ by design.
            const cppOp = m.name == "opEquals" ? "operator==" : m.name == "opCmp" ? "operator<" : null;
            if (cppOp.length)
            {
                if (!cr.methods.any!(x => x.name == cppOp))
                    dOnly("method " ~ name ~ "::" ~ m.name);
                continue;
            }
            // Accessors of C++ bitfields.
            if (m.name in cr.bitfields)
                continue;
            const cms = cr.methods.filter!(x => x.name == m.name && !x.isSpecial).array;
            if (cms.length == 0)
            {
                dOnly("method " ~ name ~ "::" ~ m.name);
                continue;
            }
            const q = name ~ "::" ~ m.name;
            bool[string] types;
            foreach (ref x; cms)
                types[x.type] = true;
            signature(q, q, m.type, types.length);
            if (m.vindex >= 0)
            {
                // The slot must hold a C++ virtual method of the same name;
                // overloads are told apart by the signature check above.
                if (m.vindex >= vorder.length || cr.methods[vorder[m.vindex]].name != m.name)
                    r.problems ~= format!"%s: D vtable slot %s, which C++ gives to %s"(q, m.vindex,
                            m.vindex < vorder.length ? cr.methods[vorder[m.vindex]].name : "nothing");
            }
            else if (cms.any!(x => x.isVirtual))
                r.problems ~= q ~ ": virtual in C++ but not in D";
        }
        if (vorder.length)
        {
            const dv = a.methods.filter!(m => m.vindex >= 0).array;
            if (dv.length != vorder.length)
                r.problems ~= format!"%s: %s virtual methods in D, %s in C++"(name, dv.length, vorder.length);
            if (cr.bases)
                r.problems ~= name ~ ": C++ base classes are not modelled";
        }
        bool[string] seen;
        foreach (ref m; cr.methods)
        {
            if (m.isSpecial || m.name in seen)
                continue;
            seen[m.name] = true;
            const dname = m.name == "operator==" ? "opEquals" : m.name == "operator<" ? "opCmp" : m.name;
            if (m.name.among("operator!=", "operator>", "operator=", "operator<=", "operator>="))
                continue;
            // The flat API exports most inline struct methods as
            // SteamAPI_<struct>_<method>, which the bindings declare.
            const flat = "SteamAPI_" ~ name ~ "_" ~ m.name;
            if (!a.members.canFind(dname) && !d.functions.any!(f => f.name == flat))
                cppOnly("method " ~ name ~ "::" ~ m.name);
        }
    }
    foreach (name, ref cr; c.records)
        if (name !in d.aggregates && !cfg.names.renames.byValue.canFind(name))
            cppOnly((cr.isInterface ? "interface " : "record ") ~ name);
    foreach (name, _; c.forwardOnly)
        if (name !in d.aggregates)
            cppOnly("opaque " ~ name);

    // Enums.
    foreach (name, ref e; d.enums)
    {
        const ce = name in c.enums;
        if (!ce)
        {
            dOnly("enum " ~ name);
            continue;
        }
        ++r.matched;
        check(format!"sizeof(%s) == %s"(name, e.size), "sizeof " ~ name);
        const scope_ = name.lastIndexOf("::") < 0 ? "" : name[0 .. name.lastIndexOf("::") + 2];
        const base = e.base;
        foreach (i, v; e.values)
        {
            if (!ce.values.canFind(v))
            {
                dOnly("enumerator " ~ name ~ "::" ~ v);
                continue;
            }
            check(format!"(long long)(%s)%s%s == %sLL"(base, scope_, v,
                    signedLiteral(e.numbers[i])), "value of " ~ name ~ "::" ~ v);
        }
        foreach (v; ce.values)
            if (!e.values.canFind(v))
                cppOnly("enumerator " ~ name ~ "::" ~ v);
    }
    foreach (name, _; c.enums)
        if (name !in d.enums)
            cppOnly("enum " ~ name);

    // Constants.
    bool[string] dConsts;
    foreach (ref k; d.consts)
    {
        dConsts[k.name] = true;
        if (auto fn = k.name in cfg.interfaceVersionLists)
        {
            ++r.matched;
            const want = decodeDumpString(k.value[2 .. $]);
            const lits = *fn in c.functionStrings;
            if (!lits || !(*lits).canFind(want))
                r.problems ~= k.name ~ " differs from the interface version list in " ~ *fn;
            continue;
        }
        string expr;
        string ckind;
        if (auto en = k.type in d.enums)
        {
            const ce = k.type in c.enums;
            const unq = k.name[k.name.lastIndexOf(':') + 1 .. $];
            if (ce && ce.values.canFind(unq))
            {
                const s = k.type.lastIndexOf("::");
                expr = (s < 0 ? "" : k.type[0 .. s + 2]) ~ unq;
                ckind = "enumerator";
            }
        }
        if (!expr.length)
        {
            if (auto ck = k.name in c.constKind)
            {
                expr = k.name;
                ckind = *ck;
            }
            else if (auto mv = k.name in c.macros)
            {
                if ((*mv).length)
                {
                    expr = k.name;
                    ckind = "macro";
                }
            }
        }
        if (!expr.length)
        {
            dOnly("constant " ~ k.name);
            continue;
        }
        ++r.matched;
        if (ckind == "var")
            check(format!"sw_eq<sw_unconst<decltype(%s)>::type, %s>::value"(expr, k.type),
                    "type of " ~ k.name ~ " is " ~ k.type);
        else if (ckind == "enumerator")
            check(format!"sw_same<decltype(%s), %s>::value"(expr, k.type), "type of " ~ k.name ~ " is " ~ k.type);
        if (k.value.startsWith("s:"))
            check(format!"sw_str(%s, %s)"(expr,
                    cppStringLiteral(decodeDumpString(k.value[2 .. $]))), "value of " ~ k.name);
        else if (k.value.startsWith("f:"))
        {
            // C++ cannot read a `const float` in a constant expression; the
            // initializer comes from the AST instead.
            if (auto fv = expr in c.floatValues)
            {
                if (cast(long)(*fv * 1e6) != k.value[2 .. $].to!long)
                    r.problems ~= format!"value of %s: D %s, C++ %s (x 1e6)"(k.name,
                            k.value[2 .. $], cast(long)(*fv * 1e6));
            }
            else
                check(format!"(long long)((%s) * 1e6) == %sLL"(expr, k.value[2 .. $]), "value of " ~ k.name);
        }
        else if (k.value == "?")
            check(format!"sizeof((%s)) == sizeof(%s)"(expr, k.type), "type size of " ~ k.name);
        else
        {
            // Enumerators compare through the D base type: MSVC gives
            // ERemoteStoragePlatform a signed base where D and GCC use unsigned.
            const vt = k.type in d.enums ? d.enums[k.type].base : k.type;
            check(format!"(long long)(%s)(%s) == %sLL"(vt, expr, signedLiteral(k.value)), "value of " ~ k.name);
        }
    }
    foreach (name, kind; c.constKind)
        if (kind != "enumerator" && name !in dConsts)
            cppOnly("constant " ~ name);
    foreach (name, value; c.macros)
    {
        if (value.length == 0 || name in dConsts || name in d.aliases || name in d.aggregates)
            continue;
        cppOnly("macro " ~ name);
    }
    foreach (name, _; c.macroFunctions)
        cppOnly("function-macro " ~ name);

    // Aliases.
    foreach (name, type; d.aliases)
    {
        if (name !in c.typedefs && name !in c.macros)
        {
            dOnly("alias " ~ name);
            continue;
        }
        ++r.matched;
        check(format!"sw_eq<%s, %s>::value"(name, type), "alias " ~ name ~ " = " ~ type);
    }
    foreach (name, _; c.typedefs)
        if (name !in d.aliases && name !in d.aggregates && name !in d.enums)
            cppOnly("typedef " ~ name);
    foreach (name, _; c.templates)
        cppOnly("template " ~ name);

    // Functions.
    bool[string] dFuncs;
    foreach (ref f; d.functions)
    {
        dFuncs[f.name] = true;
        const cf = f.name in c.functions;
        if (!cf)
        {
            dOnly("function " ~ f.name);
            continue;
        }
        ++r.matched;
        if (cf.externC && !cf.isInline && f.linkage != "C")
            r.problems ~= format!"%s: extern \"C\" in the headers, extern(%s) %s in D"(f.name, f.linkage, f.kind);
        if (f.type.startsWith("?"))
            r.problems ~= f.name ~ ": unsupported D signature " ~ f.type;
        const overloads = f.name in c.functionTypes ? c.functionTypes[f.name].length : 1;
        signature(f.name, f.name, f.type, overloads);
    }
    foreach (name, ref cf; c.functions)
        if (name !in dFuncs)
            cppOnly((cf.externC ? "function " : "inline-function ") ~ name);

    foreach (g; d.others)
        dOnly("declaration " ~ g);

    // Unsupported D types anywhere make the C++ check fail to compile; name them.
    foreach (line; o.lineSplitter)
        if (line.canFind("?"))
            r.problems ~= "unsupported D type in: " ~ line;
    r.cpp = o;
    return r;
}

/// An integer literal for C++ from a dump value of type `type`; values of
/// unsigned 64-bit types wrap like the `(long long)` cast the check applies.
string signedLiteral(string value) @safe pure
{
    if (value.length && value[0] != '-' && value.to!ulong > long.max)
        return (cast(long) value.to!ulong).to!string;
    if (value == long.min.to!string)
        return "(-9223372036854775807LL - 1)";
    return value;
}

unittest
{
    assert(signedLiteral("18446744073709551615") == "-1");
    assert(signedLiteral("4294967295") == "4294967295");
}

/// Reports the exceptions that matched nothing in any comparison.
string[] staleExceptions(const ref VerifyConfig cfg)
{
    string[] r;
    foreach (ref e; cfg.cppOnly)
        if (!e.uses)
            r ~= "abiVerify.cppOnly entry matches nothing: " ~ e.pattern;
    foreach (ref e; cfg.dOnly)
        if (!e.uses)
            r ~= "abiVerify.dOnly entry matches nothing: " ~ e.pattern;
    foreach (ref e; cfg.constRelaxed)
        if (!e.uses)
            r ~= "abiVerify.constRelaxed entry matches nothing: " ~ e.pattern;
    return r;
}

// ---------------------------------------------------------------------------
// Driver.

/// Includes of the inventory translation unit (the same as the probe's).
enum string inventorySource = q"CPP
#define VERSION_SAFE_STEAM_API_INTERFACES
#define USE_BREAKPAD_HANDLER
#include "steam/steam_api_flat.h"
#include "steam/steam_gameserver.h"
#include "steam/isteamdualsense.h"
#include "steam/steamnetworkingfakeip.h"
#include "steam/isteamappticket.h"
#include "steam/isteamgamecoordinator.h"
CPP";

/// The ldc2 triple of the machine running the verifier, which dmd targets;
/// empty where no probed target matches.
string nativeTarget() @safe pure nothrow
{
    version (OSX)
    {
        version (AArch64)
            return "arm64-apple-macos";
        else version (X86_64)
            return "x86_64-apple-macos";
        else
            return "";
    }
    else version (linux)
    {
        version (X86_64)
            return "x86_64-linux-gnu";
        else version (AArch64)
            return "aarch64-linux-gnu";
        else
            return "";
    }
    else version (Windows)
    {
        version (X86_64)
            return "x86_64-windows-msvc";
        else
            return "";
    }
    else
        return "";
}

/// The Steam API library Valve ships for a target, and how its symbol names
/// are decorated.
struct TargetLibrary
{
    string path; /// under sdk/redistributable_bin
    string[] nmArgs; /// nm options listing the exported (or, for an import library, defined) symbols
    bool underscore; /// C names carry a leading underscore (Mach-O, 32-bit Windows)
}

/// The library for a clang triple.
TargetLibrary targetLibrary(string clangTriple) @safe pure
{
    if (clangTriple.startsWith("arm64-apple"))
        return TargetLibrary("osx/libsteam_api.dylib", ["-gU", "-arch", "arm64"], true);
    if (clangTriple.startsWith("x86_64-apple"))
        return TargetLibrary("osx/libsteam_api.dylib", ["-gU", "-arch", "x86_64"], true);
    if (clangTriple == "x86_64-pc-windows-msvc")
        return TargetLibrary("win64/steam_api64.lib", ["--defined-only"], false);
    if (clangTriple == "i686-pc-windows-msvc")
        return TargetLibrary("steam_api.lib", ["--defined-only"], true);
    if (clangTriple == "x86_64-linux-gnu")
        return TargetLibrary("linux64/libsteam_api.so", ["-D", "--defined-only"], false);
    if (clangTriple == "i686-linux-gnu")
        return TargetLibrary("linux32/libsteam_api.so", ["-D", "--defined-only"], false);
    if (clangTriple == "aarch64-linux-gnu")
        return TargetLibrary("linuxarm64/libsteam_api.so", ["-D", "--defined-only"], false);
    if (clangTriple == "aarch64-linux-android")
        return TargetLibrary("androidarm64/libsteam_api.so", ["-D", "--defined-only"], false);
    throw new Exception("no library for " ~ clangTriple);
}

/// Symbol names from `nm` output (the last field of each line), with the
/// platform's C underscore removed; import-library thunks (`__imp_`) are skipped.
string[] nmSymbols(string output, bool underscore) @safe pure
{
    string[] r;
    foreach (line; output.lineSplitter)
    {
        const f = line.split;
        if (f.length == 0 || f[$ - 1].endsWith(":"))
            continue;
        string n = f[$ - 1];
        if (n.startsWith("__imp_"))
            continue;
        if (underscore)
        {
            if (!n.startsWith("_"))
                continue;
            n = n[1 .. $];
        }
        r ~= n;
    }
    return r;
}

unittest
{
    assert(nmSymbols("         U _SteamAPI_Init\n00000000 T __imp__SteamAPI_Init\n", true) == [
        "SteamAPI_Init"
    ]);
    assert(nmSymbols("0000 T SteamAPI_Init\nlib.so:\n", false) == ["SteamAPI_Init"]);
}

/// Whether an exported name belongs to the C runtime statically linked into
/// some of the libraries rather than to the Steam API.
bool isRuntimeExport(string n) @safe pure
{
    return n.startsWith("_Z") || n.startsWith("__") || n.startsWith("_init")
        || n.startsWith("_fini") || n == "SteamRealPath" || n.startsWith("_D") || n.startsWith("_d_")
        || n == "_end" || n == "_edata" || n == "_bss_start";
}

/// The names an import library (`.lib`) makes available: those with an
/// `__imp_` pointer, which covers functions and data.
string[] importLibraryExports(string nmOutput, bool underscore) @safe pure
{
    string[] r;
    foreach (line; nmOutput.lineSplitter)
    {
        const f = line.split;
        if (f.length == 0 || !f[$ - 1].startsWith("__imp_"))
            continue;
        auto m = f[$ - 1]["__imp_".length .. $];
        if (underscore)
        {
            if (!m.startsWith("_"))
                continue;
            m = m[1 .. $];
        }
        r ~= m;
    }
    return r;
}

unittest
{
    assert(importLibraryExports("0 T __imp__SteamAPI_Init\n0 T _SteamAPI_Init\n0 R .idata$2\n",
            true) == ["SteamAPI_Init"]);
    assert(importLibraryExports("0 T __imp_SteamAPI_Init\n0 D __imp_g_p\n", false) == [
        "SteamAPI_Init", "g_p"
    ]);
}

/// Compares, for one target, the extern(C) functions the bindings declare
/// with the undefined symbols of the linked configuration's object (proving
/// the symbol names the compiler emits) and with the exports of Valve's
/// library. Returns the problems found.
string[] compareLinkSymbols(const string[] cFunctions, const string[] undefinedSyms,
        const string[] exportedSyms, const string[] unbound)
{
    string[] r;
    bool[string] exported, undefined, declared;
    foreach (n; exportedSyms)
        exported[n] = true;
    foreach (n; undefinedSyms)
        undefined[n] = true;
    foreach (n; cFunctions)
        declared[n] = true;
    foreach (n; declared.keys.sort)
    {
        if (n !in undefined)
            r ~= "the linked object does not reference " ~ n;
        if (n !in exported)
            r ~= "the library does not export " ~ n;
    }
    foreach (n; exported.keys.sort)
        if (n !in declared && !unbound.canFind(n) && !isRuntimeExport(n))
            r ~= "exported but not bound: " ~ n;
    foreach (n; unbound)
        if (n !in exported)
            r ~= "listed in unboundExports but not exported: " ~ n;
    return r;
}

unittest
{
    assert(compareLinkSymbols(["SteamAPI_Init"], ["SteamAPI_Init", "memcpy"], [
        "SteamAPI_Init", "GetHSteamPipe", "_ZN1x"
    ], ["GetHSteamPipe"]).length == 0);
    assert(compareLinkSymbols(["SteamAPI_Nope"], [], ["SteamAPI_Init"], []).length == 3);
}

/// Options of a verification run.
struct VerifyOptions
{
    string root = "."; /// repository root
    string sdkInclude = "sdk/public";
    string clang = "clang++";
    string ldc = "ldc2";
    string dmd = "dmd"; /// empty to skip dmd
    string nm = "nm"; /// an nm that reads Mach-O, ELF and COFF (llvm-nm)
    string libraries = "sdk/redistributable_bin";
    string workDir; /// kept when set; a temporary directory otherwise
}

/// Runs the whole verification; returns the number of failures.
int runVerify(const ref JSONValue overrides, VerifyOptions opt)
{
    import std.file : exists, mkdirRecurse, read, rmdirRecurse, tempDir, write;
    import std.path : buildPath;
    import std.process : execute, thisProcessID;
    import std.stdio : stdout, writefln, writeln;
    import gen.probe : stubHeaders, targets;

    auto cfg = verifyConfig(overrides);
    const keep = opt.workDir.length > 0;
    const work = keep ? opt.workDir : buildPath(tempDir, format!"steamworks-verify-%s"(thisProcessID));
    mkdirRecurse(buildPath(work, "stub"));
    scope (exit)
        if (!keep)
            rmdirRecurse(work);
    foreach (name, text; stubHeaders)
        write(buildPath(work, "stub", name), text);
    const inventoryCpp = buildPath(work, "inventory.cpp");
    write(inventoryCpp, inventorySource);

    const src = buildPath(opt.root, "source");
    const dump = buildPath(opt.root, "tests", "abi", "reflect", "dump.d");
    int failures;

    string[] unbound;
    foreach (ref u; overrides["unboundExports"]["names"].array)
        unbound ~= u.str;
    const linkrefs = buildPath(opt.root, "tests", "abi", "reflect", "linkrefs.d");

    // Compiles linkrefs.d for the target and compares its undefined symbols
    // with the target library's exports.
    string[] linkCheck(const string[] run, string clangTriple, const string[] cFunctions)
    {
        const obj = buildPath(work, format!"linkrefs-%s-%s.o"(run[0], clangTriple));
        auto cmd = run[2 .. $].filter!(a => a.length).array ~ [
            "-c", "-of=" ~ obj, "-I" ~ src, "-J" ~ buildPath(src, "steamworks", "raw"), linkrefs
        ];
        auto cr = execute(cmd);
        if (cr.status != 0)
            return ["compiling linkrefs.d failed: " ~ cr.output];
        const lib = targetLibrary(clangTriple);
        auto ur = execute([opt.nm, "-u", obj]);
        auto er = execute([opt.nm] ~ lib.nmArgs ~ [buildPath(opt.libraries, lib.path)]);
        if (ur.status != 0 || er.status != 0)
            return ["nm failed: " ~ ur.output ~ er.output];
        const exported = lib.path.endsWith(".lib") ? importLibraryExports(er.output,
                lib.underscore) : nmSymbols(er.output, lib.underscore);
        return compareLinkSymbols(cFunctions, nmSymbols(ur.output, lib.underscore), exported, unbound);
    }

    foreach (t; targets)
    {
        const flags = [
            "-target", t.clang, "-std=c++17", "-ffreestanding", "-nostdinc++", "-isystem",
            buildPath(work, "stub"), "-I", opt.sdkInclude
        ];
        auto astRun = execute([opt.clang] ~ flags ~ [
            "-fsyntax-only", "-Xclang", "-ast-dump=json", inventoryCpp
        ]);
        enforce(astRun.status == 0, "clang AST dump failed for " ~ t.clang ~ ":\n" ~ astRun.output);
        auto astText = cast(char[]) astRun.output.dup;
        foreach (ref ch; astText)
            if (ch >= 0x80)
                ch = '?';
        auto ast = parseJSON(astText);
        astText = null;
        auto inv = cppInventory(ast);
        ast = JSONValue.init;
        auto macroRun = execute([opt.clang] ~ flags ~ ["-E", "-dD", inventoryCpp]);
        enforce(macroRun.status == 0, "clang -E failed for " ~ t.clang ~ ":\n" ~ macroRun.output);
        readMacros(macroRun.output, inv);
        const msvc = t.clang.canFind("windows-msvc");

        string[][] runs;
        foreach (dyn; [false, true])
        {
            runs ~= [
                "ldc2", dyn ? "dynamic" : "linked", opt.ldc, "-mtriple=" ~ t.ldc,
                dyn ? "-d-version=SteamworksDynamic" : null
            ];
            if (opt.dmd.length && t.ldc == nativeTarget)
                runs ~= [
                "dmd", dyn ? "dynamic" : "linked", opt.dmd, dyn ? "-version=SteamworksDynamic" : null
            ];
        }
        foreach (run; runs)
        {
            const label = format!"%s %s (%s)"(run[0], t.clang, run[1]);
            auto cmd = run[2 .. $].filter!(a => a.length).array ~ [
                "-o-", "-c", "-I" ~ src, "-J" ~ buildPath(src, "steamworks", "raw"), dump
            ];
            auto dr = execute(cmd);
            if (dr.status != 0)
            {
                writefln("FAIL  %s: describing the bindings failed:\n%s", label, dr.output);
                ++failures;
                continue;
            }
            auto d = readDump(dr.output, cfg.names);
            auto cmp = compare(d, inv, cfg, msvc);
            if (run[1] == "linked")
            {
                const cFunctions = d.functions
                    .filter!(f => f.linkage == "C" && f.kind == "func")
                    .map!(f => f.name)
                    .array;
                cmp.problems ~= linkCheck(run, t.clang, cFunctions);
            }
            const checkFile = buildPath(work, format!"check-%s-%s-%s.cpp"(run[0], t.clang, run[1]));
            write(checkFile, cmp.cpp);
            auto cr = execute([opt.clang] ~ flags ~ [
                "-fsyntax-only", "-ferror-limit=0", "-Wno-invalid-offsetof", checkFile
            ]);
            string[] errors;
            foreach (line; cr.output.lineSplitter)
                if (line.canFind("error:"))
                    errors ~= line[line.indexOf("error:") .. $];
            if (cr.status != 0 && errors.length == 0)
                errors ~= cr.output;
            if (cmp.problems.length || errors.length)
            {
                writefln("FAIL  %s: %s checks, %s declarations matched", label, cmp.checks, cmp.matched);
                foreach (p; cmp.problems)
                    writeln("      ", p);
                foreach (e; errors)
                    writeln("      ", e);
                if (keep)
                    writeln("      checks: ", checkFile);
                ++failures;
            }
            else
                writefln("ok    %s: %s checks, %s declarations matched", label, cmp.checks, cmp.matched);
            stdout.flush();
        }
    }
    foreach (s; staleExceptions(cfg))
    {
        writeln("FAIL  ", s);
        ++failures;
    }
    return failures;
}
