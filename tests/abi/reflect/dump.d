/// Describes the D bindings as the compiler sees them, for the target being
/// compiled, by printing one line per declaration with `pragma(msg)`.
///
/// tools/gen (`--verify`) reads this description, turns it into C++
/// static_asserts against the SDK headers and compares it with clang's view
/// of the headers. Compile it without code generation, for any target:
///
///   ldc2 -mtriple=<triple> -o- -c -Isource -Jsource/steamworks/raw tests/abi/reflect/dump.d
///
/// Line format (tab-separated; names are D-qualified without the module,
/// types are C++ expressions over the sw_* aliases of the verifier's prelude):
///   M module                                  a module being described
///   S name kind size align                    struct, union, class or opaque struct
///   F owner field offset size type visibility data member
///   P owner name                              any other member of an aggregate
///   R owner name vindex type                  virtual method of an extern(C++) class
///   N owner name static type                  non-virtual method ("static" or "-")
///   E name base size                          enum
///   V enum member value                       enumerator
///   K name type value                         manifest constant (value: integer,
///                                             "f:" float*1e6, "s:" string, "?" other)
///   T name type                               alias to a type
///   X name linkage kind type                  function ("func") or function pointer
///                                             variable ("ptr"); type is a sw_fn
///   G name                                    other module-level declaration
///   Z                                         end of the description
module abi_dump;

/// The modules `steamworks.raw` publicly imports, read from its package.d.
private string[] rawModules(string packageSource)
{
    string[] r;
    enum prefix = "public import ";
    size_t i;
    while (i < packageSource.length)
    {
        size_t j = i;
        while (j < packageSource.length && packageSource[j] != '\n')
            ++j;
        auto line = packageSource[i .. j];
        if (line.length > prefix.length && line[0 .. prefix.length] == prefix && line[$ - 1] == ';')
            r ~= line[prefix.length .. $ - 1];
        i = j + 1;
    }
    return r;
}

private enum string[] modules = rawModules(import("package.d"));
static assert(modules.length > 10, "no modules found in steamworks/raw/package.d");

private string importDecls(string[] mods)
{
    string r;
    foreach (m; mods)
        r ~= "static import " ~ m ~ ";\n";
    return r;
}

mixin(importDecls(modules));
import steamworks.raw;

private string itoa(long v)
{
    if (v == long.min)
        return "-9223372036854775808";
    if (v < 0)
        return "-" ~ itoa(-v);
    if (v < 10)
        return [cast(char)('0' + v)];
    return itoa(v / 10) ~ cast(char)('0' + v % 10);
}

private string utoa(ulong v)
{
    if (v < 10)
        return [cast(char)('0' + v)];
    return utoa(v / 10) ~ cast(char)('0' + v % 10);
}

/// The name of a symbol qualified by its enclosing aggregates, without the module.
template qualName(alias sym)
{
    static if (__traits(isModule, __traits(parent, sym)))
        enum qualName = __traits(identifier, sym);
    else
        enum qualName = qualName!(__traits(parent, sym)) ~ "." ~ __traits(identifier, sym);
}

/// druntime's C `long` types, which are enums the compiler gives C++ semantics.
private enum string[string] cMagic = [
    "__c_long": "long", "__c_ulong": "unsigned long", "__c_longlong": "long long",
    "__c_ulonglong": "unsigned long long"
];

private enum bool isMagicC(T) = (__traits(identifier, T) in cMagic) !is null;

/// The C++ spelling of a D type, over the sw_* aliases.
template cppType(T)
{
    static if (is(T == string))
        enum cppType = "string";
    else static if (is(T == immutable U, U) || is(T == const U, U))
    {
        static if (is(U == class))
            enum cppType = "sw_p<sw_c<" ~ qualName!U ~ ">>";
        else
            enum cppType = "sw_c<" ~ cppType!U ~ ">";
    }
    else static if (is(T == shared U, U))
        enum cppType = "?shared";
    else static if (is(T == enum) && isMagicC!T)
        enum cppType = cMagic[__traits(identifier, T)];
    else static if (is(T == V*, V))
    {
        static if (is(V == function))
            enum cppType = fnType!V;
        else
            enum cppType = "sw_p<" ~ cppType!V ~ ">";
    }
    else static if (is(T == U[N], U, size_t N))
        enum cppType = "sw_a<" ~ cppType!U ~ ", " ~ utoa(N) ~ ">";
    else static if (is(T == enum) || is(T == struct) || is(T == union))
        enum cppType = qualName!T;
    else static if (is(T == class))
        enum cppType = "sw_p<" ~ qualName!T ~ ">";
    else static if (is(T == void))
        enum cppType = "void";
    else static if (is(T == bool))
        enum cppType = "bool";
    else static if (is(T == char))
        enum cppType = "char";
    else static if (is(T == byte))
        enum cppType = "signed char";
    else static if (is(T == ubyte))
        enum cppType = "unsigned char";
    else static if (is(T == short))
        enum cppType = "short";
    else static if (is(T == ushort))
        enum cppType = "unsigned short";
    else static if (is(T == int))
        enum cppType = "int";
    else static if (is(T == uint))
        enum cppType = "unsigned int";
    else static if (is(T == long))
        enum cppType = "long long";
    else static if (is(T == ulong))
        enum cppType = "unsigned long long";
    else static if (is(T == float))
        enum cppType = "float";
    else static if (is(T == double))
        enum cppType = "double";
    else
        enum cppType = "?" ~ T.stringof;
}

/// Parameter list of a function type, with `ref` as a C++ reference.
template paramTypes(F)
{
    static if (is(F P == __parameters))
        enum paramTypes = () {
            string r;
            static foreach (i; 0 .. P.length)
                {
                {
                    string t = cppType!(P[i]);
                    static foreach (sc; __traits(getParameterStorageClasses, F, i))
                        {
                        static if (sc == "ref")
                            t = "sw_r<" ~ t ~ ">";
                        else static if (sc == "out" || sc == "lazy")
                            t = "?" ~ sc;
                    }
                    r ~= ", " ~ t;
                }
            }
            return r;
        }();
}

/// Return type, with `ref` as a C++ reference.
template returnType(F)
{
    static if (is(F R == return))
    {
        static if (hasAttribute(__traits(getFunctionAttributes, F), "ref"))
            enum returnType = "sw_r<" ~ cppType!R ~ ">";
        else
            enum returnType = cppType!R;
    }
}

/// A function type as `sw_fn<R, P...>`; D linkage or C-style varargs are
/// marked so the verifier rejects them.
template fnType(F)
{
    enum string variadic = __traits(getFunctionVariadicStyle, F);
    enum fnType = (variadic == "none" ? "" : "?variadic ") ~ "sw_fn<" ~ returnType!F ~ paramTypes!F ~ ">";
}

/// A method type as `sw_mfn<Owner, R, P...>` or `sw_mfnc` when const.
template methodType(Owner, alias f)
{
    alias F = typeof(f);
    enum bool isConst = hasAttribute(__traits(getFunctionAttributes, f), "const");
    enum methodType = (isConst ? "sw_mfnc<" : "sw_mfn<") ~ qualName!Owner ~ ", " ~ returnType!F ~ paramTypes!F ~ ">";
}

private bool hasAttribute(string[] attrs...)
{
    foreach (a; attrs[0 .. $ - 1])
        if (a == attrs[$ - 1])
            return true;
    return false;
}

private string constValue(T)(T v)
{
    static if (is(T == string))
    {
        string r = "s:";
        foreach (c; v)
            r ~= c == '\\' ? "\\\\" : c == '\t' ? "\\t" : c == '\n' ? "\\n" : c == 0 ? "\\0" : [c];
        return r;
    }
    else static if (is(T : real) && (is(T == float) || is(T == double) || is(T == real)))
        return "f:" ~ itoa(cast(long)(v * 1e6));
    else static if (is(T == enum) || __traits(isIntegral, T) || is(T == bool))
    {
        static if (__traits(isUnsigned, T) || (is(T B == enum) && __traits(isUnsigned, B)))
            return utoa(cast(ulong) v);
        else
            return itoa(cast(long) v);
    }
    else
        return "?";
}

private enum bool isType(alias sym) = is(sym);
private enum bool isManifest(alias sym) = __traits(compiles, { enum e = sym; }) && !__traits(compiles, {
                auto p = &sym;
            });

/// Describes one aggregate type (and its nested types).
template describeAggregate(T)
{
    enum string name = qualName!T;
    static if (is(T == class))
    {
        enum string head = "S\t" ~ name ~ "\tclass\t" ~ utoa(__traits(classInstanceSize, T)) ~ "\t-";
    }
    else static if (__traits(compiles, T.sizeof))
        enum string head = "S\t" ~ name ~ "\t" ~ (is(T == union)
                    ? "union" : "struct") ~ "\t" ~ utoa(T.sizeof) ~ "\t" ~ utoa(T.alignof);
    else
        enum string head = "S\t" ~ name ~ "\topaque\t-\t-";
    pragma(msg, head);
    static if (__traits(compiles, T.tupleof))
        static foreach (i, f; T.tupleof)
            pragma(msg, "F\t" ~ name ~ "\t" ~ __traits(identifier,
                    T.tupleof[i]) ~ "\t" ~ utoa(T.tupleof[i].offsetof) ~ "\t" ~ utoa(typeof(T.tupleof[i])
                    .sizeof) ~ "\t" ~ cppType!(typeof(T.tupleof[i])) ~ "\t" ~ __traits(getVisibility, T.tupleof[i]));
    static if (__traits(compiles, __traits(allMembers, T)))
        static foreach (m; __traits(allMembers, T))
            static if (!isField!(T, m))
                mixin describeMember!(T, m);
    enum describeAggregate = true;
}

/// Whether `m` names a data member of `T`.
template isField(T, string m)
{
    enum bool isField = () {
        static if (__traits(compiles, T.tupleof))
            static foreach (i; 0 .. T.tupleof.length)
                if (__traits(identifier, T.tupleof[i]) == m)
                    return true;
        return false;
    }();
}

/// Describes one non-field member of an aggregate.
mixin template describeMember(T, string m)
{
    static if (!__traits(compiles, __traits(getMember, T, m)))
    {
        pragma(msg, "P\t" ~ qualName!T ~ "\t" ~ m);
    }
    else static if (isType!(__traits(getMember, T, m)) && (is(__traits(getMember, T, m) == struct)
            || is(__traits(getMember, T, m) == union) || is(__traits(getMember, T, m) == class))
            && __traits(identifier, __traits(getMember, T, m)) == m && is(__traits(parent,
                __traits(getMember, T, m)) == T))
    {
        pragma(msg, "P\t" ~ qualName!T ~ "\t" ~ m);
        static assert(describeAggregate!(__traits(getMember, T, m)));
    }
    else static if (isType!(__traits(getMember, T, m)) && is(__traits(getMember, T, m) == enum)
            && __traits(identifier, __traits(getMember, T, m)) == m)
    {
        pragma(msg, "P\t" ~ qualName!T ~ "\t" ~ m);
        static assert(describeEnum!(__traits(getMember, T, m)));
    }
    else static if (isType!(__traits(getMember, T, m)))
    {
        pragma(msg, "P\t" ~ qualName!T ~ "\t" ~ m);
    }
    else static if (is(typeof(__traits(getMember, T, m)) == function) && m != "__ctor"
            && m != "__dtor" && m != "__xdtor" && m != "__xpostblit" && m != "__postblit")
    {
        pragma(msg, "P\t" ~ qualName!T ~ "\t" ~ m);
        static foreach (f; __traits(getOverloads, T, m))
        {
            static if (__traits(getVisibility, f) == "private")
            {
                // Implementation detail of the D type.
            }
            else static if (__traits(isVirtualMethod, f))
                pragma(msg, "R\t" ~ qualName!T ~ "\t" ~ m ~ "\t" ~ itoa(__traits(getVirtualIndex,
                        f)) ~ "\t" ~ methodType!(T, f));
            else static if (__traits(isStaticFunction, f))
                pragma(msg, "N\t" ~ qualName!T ~ "\t" ~ m ~ "\tstatic\t" ~ fnType!(typeof(f)));
            else
                pragma(msg, "N\t" ~ qualName!T ~ "\t" ~ m ~ "\t-\t" ~ methodType!(T, f));
        }
    }
    else static if (isManifest!(__traits(getMember, T, m)))
    {
        pragma(msg, "P\t" ~ qualName!T ~ "\t" ~ m);
        pragma(msg, "K\t" ~ qualName!T ~ "." ~ m ~ "\t" ~ cppType!(typeof(__traits(getMember, T,
                m))) ~ "\t" ~ constValue(__traits(getMember, T, m)));
    }
    else
    {
        pragma(msg, "P\t" ~ qualName!T ~ "\t" ~ m);
    }
}

/// Describes an enum and its members.
template describeEnum(E)
{
    static if (is(E B == enum))
        pragma(msg, "E\t" ~ qualName!E ~ "\t" ~ cppType!B ~ "\t" ~ utoa(E.sizeof));
    static foreach (v; __traits(allMembers, E))
        pragma(msg, "V\t" ~ qualName!E ~ "\t" ~ v ~ "\t" ~ constValue(__traits(getMember, E, v)));
    enum describeEnum = true;
}

/// Describes one module-level declaration.
mixin template describeTop(alias mod, string modName, string m)
{
    // Private declarations (including private aliases, which have no
    // visibility of their own) are not accessible by qualified name.
    static if (!__traits(compiles, mixin(modName ~ "." ~ m)) || !__traits(compiles, __traits(getMember, mod, m)))
    {
    }
    else static if (__traits(isModule, __traits(getMember, mod, m)) || __traits(isPackage, __traits(getMember, mod, m)))
    {
    }
    else static if (__traits(compiles, __traits(getVisibility, __traits(getMember, mod, m)))
            && __traits(getVisibility, __traits(getMember, mod, m)) != "public")
    {
    }
    else static if (__traits(isTemplate, __traits(getMember, mod, m)))
    {
        pragma(msg, "G\t" ~ m);
    }
    else static if (isType!(__traits(getMember, mod, m)))
    {
        alias T = __traits(getMember, mod, m);
        static if ((is(T == struct) || is(T == union) || is(T == class) || is(T == enum))
                && !(is(T == enum) && isMagicC!T) && __traits(identifier, T) == m && __traits(isSame,
                    __traits(parent, T), mod))
        {
            static if (is(T == enum))
                static assert(describeEnum!T);
            else
                static assert(describeAggregate!T);
        }
        else
            pragma(msg, "T\t" ~ m ~ "\t" ~ cppType!T);
    }
    else static if (is(typeof(__traits(getMember, mod, m)) == function))
    {
        static foreach (f; __traits(getOverloads, mod, m))
            pragma(msg, "X\t" ~ m ~ "\t" ~ __traits(getLinkage, f) ~ "\tfunc\t" ~ fnType!(typeof(f)));
    }
    else static if (isManifest!(__traits(getMember, mod, m)))
    {
        pragma(msg, "K\t" ~ m ~ "\t" ~ cppType!(typeof(__traits(getMember, mod,
                m))) ~ "\t" ~ constValue(__traits(getMember, mod, m)));
    }
    else static if (is(typeof(__traits(getMember, mod, m)) P == U*, U) && is(U == function))
    {
        pragma(msg, "X\t" ~ m ~ "\t" ~ __traits(getLinkage, U) ~ "\tptr\t" ~ fnType!U);
    }
    else
    {
        pragma(msg, "G\t" ~ m);
    }
}

static foreach (mname; modules)
{
    pragma(msg, "M\t" ~ mname);
    static foreach (m; __traits(allMembers, mixin(mname)))
        mixin describeTop!(mixin(mname), mname, m);
}

pragma(msg, "Z");
