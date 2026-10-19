/// The binding model: steam_api.json merged with overrides.json and the facts
/// recovered from the headers.
module gen.model;

import std.algorithm : canFind, map, startsWith;
import std.array : array;
import std.exception : enforce;
import std.format : format;
import std.json;

import gen.ctype;
import gen.headers;

/// A typedef: either a parsed C type or a verbatim D declaration.
struct Typedef
{
    string name;
    CType type;
    /// Verbatim D declaration replacing the C type, if any.
    string dCode;
    string doc;
    string header;
}

/// A named constant.
struct Const
{
    string name;
    CType type;
    string cvalue;
    string header;
    /// Whether the headers do not define it (cannot be probed).
    bool jsonOnly;
}

/// One enumerator.
struct EnumValue
{
    string name;
    long value;
}

/// An enum.
struct Enum
{
    /// D name.
    string name;
    /// C++ qualified name (`ISteamHTMLSurface::EHTMLMouseButton`).
    string cname;
    EnumValue[] values;
    string header;
    /// Underlying type from overrides.json, if the JSON values are lossy.
    string baseOverride;

    /// The smallest D base type that holds every value, as a C++ compiler
    /// picks it for an unscoped enum without fixed underlying type.
    string baseType() const @safe pure nothrow
    {
        if (baseOverride.length)
            return baseOverride;
        foreach (v; values)
            if (v.value < int.min || v.value > int.max)
                return v.value > uint.max || v.value < 0 ? "long" : "uint";
        return "int";
    }
}

/// A struct field.
struct Field
{
    string name;
    CType type;
}

/// A plain or callback struct.
struct Struct
{
    string name;
    Field[] fields;
    /// Callback identifier, or -1 for plain structs.
    long callbackId = -1;
    Pack pack;
    string header;
    Const[] consts;
    Enum[] enums;
    string doc;
    /// Layout comes from steam_api.json only (not visible in the headers).
    bool jsonOnly;
}

/// A function parameter.
struct Param
{
    string name;
    CType type;
}

/// An exported C function.
struct Function
{
    string name;
    CType ret;
    Param[] params;
    string header;
    string doc;
    /// Owning interface or struct for methods; empty for free functions.
    string owner;
    /// C++ method name for methods.
    string method;
    /// Call result struct for async methods.
    string callResult;
    /// Callback struct posted by the method.
    string callback;
}

/// An interface accessor (`SteamAPI_SteamUser_v023`).
struct Accessor
{
    string kind;
    /// Unversioned name (`SteamUser`).
    string name;
    /// Exported, versioned name.
    string flatName;
}

/// A Steam interface.
struct SteamInterface
{
    string name;
    string versionString;
    Accessor[] accessors;
    Function[] methods;
    /// C++ callback interface implemented by the application.
    bool cppCallback;
    string header;
}

/// An opaque type known only by pointer.
struct Opaque
{
    string name;
    string header;
    string doc;
}

/// A hand-written enum to probe: C++ qualified name and enumerators.
struct ManualEnum
{
    string cpp;
    string[] values;
}

/// Everything the emitters need.
struct Model
{
    Typedef[] typedefs;
    Const[] consts;
    Enum[] enums;
    Struct[] structs;
    Struct[] callbacks;
    SteamInterface[] interfaces;
    Function[] freeFunctions;
    Function[] structFunctions;
    Opaque[] opaques;
    string[string] typeMap;
    string[string] manualTypes;
    string[][string] manualProbe;
    ManualEnum[string] manualEnumsProbe;
    string[string] manualConstsProbe;
    string[] unboundExports;
    string[] manualClasses;
    HeaderInfo headers;

    /// Every exported function the bindings declare, in emission order.
    const(Function)[] allFunctions() const
    {
        const(Function)[] r;
        foreach (ref i; interfaces)
            r ~= i.methods;
        r ~= structFunctions;
        r ~= freeFunctions;
        return r;
    }
}

private string field(const JSONValue v, string key, string def = null)
{
    if (auto p = key in v.object)
        return p.str;
    return def;
}

private Param[] parseParams(const JSONValue arr)
{
    Param[] ps;
    foreach (p; arr.array)
    {
        const ty = p.field("paramtype_flat", p.field("paramtype"));
        ps ~= Param(p.field("paramname"), parseCType(ty));
    }
    return ps;
}

private Function parseMethod(const JSONValue m, string owner, string header)
{
    Function f;
    f.name = m.field("methodname_flat");
    f.ret = parseCType(m.field("returntype_flat", m.field("returntype")));
    // Flat methods take the object as an explicit first parameter.
    f.params = Param("self", parseCType(owner ~ " *")) ~ parseParams(m["params"]);
    f.owner = owner;
    f.method = m.field("methodname");
    f.callResult = m.field("callresult");
    f.callback = m.field("callback");
    f.header = header;
    return f;
}

private Const parseConst(const JSONValue c, string header)
{
    return Const(c.field("constname"), parseCType(c.field("consttype")), c.field("constval"), c.field("header", header));
}

private Enum parseEnum(const JSONValue e, string header)
{
    import std.conv : to;

    Enum en;
    en.name = e.field("enumname");
    en.cname = e.field("fqname", en.name);
    en.header = header;
    foreach (v; e["values"].array)
        en.values ~= EnumValue(v.field("name"), v.field("value").to!long);
    return en;
}

private Field[] parseFields(const JSONValue arr)
{
    Field[] fs;
    foreach (f; arr.array)
        fs ~= Field(f.field("fieldname"), parseCType(f.field("fieldtype")));
    return fs;
}

/// Builds the model from parsed steam_api.json, overrides.json and the headers.
Model buildModel(const JSONValue api, const JSONValue ovr, HeaderInfo hdr)
{
    Model m;
    m.headers = hdr;

    foreach (k, v; ovr["typeMap"].object)
        m.typeMap[k] = v.str;
    foreach (k, v; ovr["manualTypes"].object)
        if (!k.startsWith("_"))
            m.manualTypes[k] = v.str;
    foreach (k, v; ovr["manualProbe"].object)
        if (!k.startsWith("_"))
            m.manualProbe[k] = v.array.map!(x => x.str).array;
    foreach (k, v; ovr["manualEnumsProbe"].object)
        if (!k.startsWith("_"))
            m.manualEnumsProbe[k] = ManualEnum(v["cpp"].str, v["values"].array.map!(x => x.str).array);
    foreach (k, v; ovr["manualConstsProbe"].object)
        if (!k.startsWith("_"))
            m.manualConstsProbe[k] = v.str;
    foreach (v; ovr["unboundExports"]["names"].array)
        m.unboundExports ~= v.str;
    foreach (v; ovr["manualClasses"]["names"].array)
        m.manualClasses ~= v.str;

    string headerOf(string cname)
    {
        if (auto p = cname in hdr.headerOf)
            return *p;
        return null;
    }

    // Typedefs: JSON order, with replacements applied in place.
    string[string] replacements;
    string[string] replacementDocs;
    foreach (r; ovr["typedefReplacements"].array)
    {
        replacements[r.field("name")] = r.field("d");
        replacementDocs[r.field("name")] = r.field("reason");
    }
    foreach (t; api["typedefs"].array)
    {
        Typedef td;
        td.name = t.field("typedef");
        if (auto p = td.name in replacements)
        {
            td.dCode = *p;
            td.doc = replacementDocs[td.name];
        }
        else
            td.type = parseCType(t.field("type"));
        m.typedefs ~= td;
    }
    foreach (t; ovr["extraTypedefs"].array)
        m.typedefs ~= Typedef(t.field("typedef", t.field("name")), parseCType(t.field("type")), null,
                t.field("doc"), t.field("header"));

    // Constants.
    bool[string] jsonOnlyConsts;
    foreach (n; ovr["jsonOnlyConsts"]["names"].array)
        jsonOnlyConsts[n.str] = true;
    foreach (c; api["consts"].array)
    {
        auto k = parseConst(c, null);
        k.jsonOnly = (k.name in jsonOnlyConsts) !is null;
        m.consts ~= k;
    }
    foreach (c; ovr["extraConsts"].array)
        m.consts ~= parseConst(c, null);

    // Enums, including those nested in interfaces.
    foreach (e; api["enums"].array)
    {
        auto en = parseEnum(e, headerOf(e.field("enumname")));
        if (auto b = en.name in ovr["enumBaseTypes"].object)
        {
            en.baseOverride = b.str;
            enforce(en.baseOverride == "uint", "unsupported enum base override " ~ en.baseOverride);
            foreach (ref v; en.values)
                v.value = cast(uint) v.value;
        }
        m.enums ~= en;
    }
    foreach (i; api["interfaces"].array)
        if (auto es = "enums" in i.object)
            foreach (e; es.array)
            {
                auto en = parseEnum(e, headerOf(i.field("classname")));
                m.typeMap[en.cname] = en.name;
                m.enums ~= en;
            }

    // Structs.
    bool[string] jsonOnlyStructs;
    foreach (k, v; ovr["jsonOnlyStructs"].object)
        if (!k.startsWith("_"))
            jsonOnlyStructs[k] = true;
    Struct makeStruct(const JSONValue s, bool isCallback)
    {
        Struct st;
        st.name = s.field("struct");
        st.fields = parseFields(s["fields"]);
        if (isCallback)
            st.callbackId = s["callback_id"].integer;
        st.jsonOnly = (st.name in jsonOnlyStructs) !is null;
        if (st.jsonOnly)
        {
            st.pack = Pack.natural;
            st.header = ovr["jsonOnlyStructs"][st.name].str;
        }
        else
        {
            auto p = st.name in hdr.packOf;
            enforce(p, "struct " ~ st.name ~ " from steam_api.json is not defined in the headers");
            st.pack = *p;
            st.header = hdr.headerOf[st.name];
        }
        st.doc = s.field("doc");
        if (auto cs = "consts" in s.object)
            foreach (c; cs.array)
                st.consts ~= parseConst(c, st.header);
        if (auto es = "enums" in s.object)
            foreach (e; es.array)
                st.enums ~= parseEnum(e, st.header);
        if (auto extra = st.name in ovr["structConsts"].object)
            foreach (c; extra.array)
                st.consts ~= parseConst(c, st.header);
        return st;
    }
    foreach (s; api["structs"].array)
    {
        const name = s.field("struct");
        if (auto ms = "methods" in s.object)
            foreach (meth; ms.array)
                m.structFunctions ~= parseMethod(meth, name, jsonOnlyStructs.get(name, false)
                        ? ovr["jsonOnlyStructs"][name].str : headerOf(name));
        if (name in m.manualTypes)
            continue;
        m.structs ~= makeStruct(s, false);
    }
    foreach (s; ovr["extraStructs"].array)
        m.structs ~= makeStruct(s, false);
    foreach (s; api["callback_structs"].array)
        m.callbacks ~= makeStruct(s, true);

    foreach (o; ovr["opaqueTypes"].array)
        m.opaques ~= Opaque(o.field("name"), o.field("header"), o.field("doc"));

    // Interfaces.
    bool[string] cppCallbacks;
    foreach (n; ovr["cppInterfaces"]["names"].array)
        cppCallbacks[n.str] = true;
    foreach (i; api["interfaces"].array)
    {
        SteamInterface itf;
        itf.name = i.field("classname");
        itf.versionString = i.field("version_string");
        itf.header = headerOf(itf.name);
        enforce(itf.header.length, "interface " ~ itf.name ~ " is not defined in the headers");
        itf.cppCallback = (itf.name in cppCallbacks) !is null;
        if (auto as = "accessors" in i.object)
            foreach (a; as.array)
                itf.accessors ~= Accessor(a.field("kind"), a.field("name"), a.field("name_flat"));
        foreach (meth; i["methods"].array)
            itf.methods ~= parseMethod(meth, itf.name, itf.header);
        foreach (ref a; itf.accessors)
        {
            Function fn;
            fn.name = a.flatName;
            fn.ret = parseCType(itf.name ~ " *");
            fn.header = itf.header;
            fn.doc = format!"Returns the %s interface (versioned %s accessor exported by the library)."(
                    itf.name, a.kind);
            itf.methods ~= fn;
        }
        m.interfaces ~= itf;
    }

    foreach (f; ovr["extraFunctions"].array)
    {
        Function fn;
        fn.name = f.field("name");
        fn.ret = parseCType(f.field("returntype"));
        fn.params = parseParams(f["params"]);
        fn.header = f.field("header");
        fn.doc = f.field("doc");
        m.freeFunctions ~= fn;
    }

    validate(m);
    return m;
}

/// Consistency checks that would otherwise surface as confusing compile errors.
void validate(const ref Model m)
{
    bool[string] seen;
    void unique(string kind, string name)
    {
        enforce(name !in seen, format!"duplicate %s '%s'"(kind, name));
        seen[name] = true;
    }

    foreach (ref f; m.allFunctions)
        unique("function", f.name);
    seen = null;
    foreach (ref e; m.enums)
        foreach (ref v; e.values)
            unique("enumerator", v.name);
    seen = null;
    foreach (ref t; m.typedefs)
        unique("typedef", t.name);
    foreach (ref s; m.structs)
        unique("type", s.name);
    foreach (ref s; m.callbacks)
        unique("type", s.name);
    foreach (ref e; m.enums)
        unique("type", e.name);
    foreach (ref i; m.interfaces)
        unique("type", i.name);
    foreach (k, _; m.manualTypes)
        unique("type", k);
}
