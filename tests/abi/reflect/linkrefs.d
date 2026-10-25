/// References every extern(C) function of `steamworks.raw`, so that the
/// object file compiled from this module (without SteamworksDynamic) lists, as
/// undefined symbols, exactly the names the linked configuration needs from
/// the Steam API library on the target. `steamworks-gen --verify` compares
/// them with each platform library's exports:
///
///   ldc2 -mtriple=<triple> -c -of=linkrefs.o -Isource -Jsource/steamworks/raw tests/abi/reflect/linkrefs.d
module abi_linkrefs;

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

private string importDecls(string[] mods)
{
    string r;
    foreach (m; mods)
        r ~= "static import " ~ m ~ ";\n";
    return r;
}

mixin(importDecls(modules));

private template isCFunction(string qualified)
{
    static if (__traits(compiles, mixin(qualified)) && is(typeof(mixin(qualified)) == function))
        enum bool isCFunction = __traits(getLinkage, mixin(qualified)) == "C";
    else
        enum bool isCFunction = false;
}

private string references()
{
    string r = "extern (C) __gshared const(void)*[] steamworksLinkReferences = [\n";
    static foreach (mname; modules)
        static foreach (m; __traits(allMembers, mixin(mname)))
            static if (isCFunction!(mname ~ "." ~ m))
                r ~= "    &" ~ mname ~ "." ~ m ~ ",\n";
    return r ~ "];\n";
}

mixin(references());
