/// steamworks-gen: generates the `steamworks.raw` bindings from the Steamworks
/// SDK (steam_api.json plus the headers) and tools/gen/overrides.json.
module app;

import std.algorithm : sort;
import std.array : array;
import std.file : exists, mkdirRecurse, readText, write;
import std.getopt;
import std.json : parseJSON;
import std.path : buildPath, dirName;
import std.stdio : stderr, writefln, writeln;

import gen.emit;
import gen.headers;
import gen.model;
import gen.probe;

int main(string[] args)
{
    string sdk = "sdk";
    string overrides = "tools/gen/overrides.json";
    string outDir = ".";
    string sdkVersion = "1.65";
    string dfmt;
    string clang = "clang++";
    bool check;
    bool abi;

    auto help = getopt(args, "sdk", "Steamworks SDK directory containing public/steam (default: sdk)",
            &sdk, "overrides", "Overrides file (default: tools/gen/overrides.json)", &overrides,
            "out", "Repository root to write into (default: .)", &outDir,
            "sdk-version", "SDK version recorded in the banner (default: 1.65)", &sdkVersion,
            "dfmt", "Format generated D with this dfmt executable", &dfmt, "check",
            "Compare instead of writing; exit 1 if anything is stale",
            &check, "abi", "Also run the clang ABI probe and regenerate tests/abi",
            &abi, "clang", "clang++ used by --abi (default: clang++)", &clang);
    if (help.helpWanted)
    {
        defaultGetoptPrinter("Usage: steamworks-gen [options]", help.options);
        return 0;
    }

    const steamDir = buildPath(sdk, "public", "steam");
    auto api = parseJSON(readText(buildPath(steamDir, "steam_api.json")));
    auto ovr = parseJSON(readText(overrides));
    string[] ignored;
    foreach (v; ovr["ignoredHeaders"]["names"].array)
        ignored ~= v.str;
    auto hdr = scanHeaders(steamDir, ignored);
    auto model = buildModel(api, ovr, hdr);

    Output files = generate(model, sdkVersion);
    files["tests/abi/probe.cpp"] = emitProbeCpp(model, sdkVersion);
    if (abi)
        files["tests/abi/source/abi_expected.d"] = runProbe(model, sdkVersion, clang,
                buildPath(sdk, "public"), buildPath(outDir, "tests", "abi"));

    if (dfmt.length)
        foreach (path, ref text; files)
            if (path[$ - 2 .. $] == ".d")
                text = format(dfmt, text);

    auto paths = files.keys;
    paths.sort();
    int stale;
    foreach (p; paths)
    {
        const full = buildPath(outDir, p);
        const old = exists(full) ? readText(full) : null;
        if (old == files[p])
            continue;
        if (check)
        {
            stderr.writefln("stale: %s", p);
            ++stale;
            continue;
        }
        mkdirRecurse(dirName(full));
        write(full, files[p]);
        writefln("wrote %s", p);
    }
    if (check && stale)
    {
        stderr.writefln("%s generated file(s) are out of date; run tools/gen/generate.sh", stale);
        return 1;
    }
    size_t fns = model.allFunctions.length;
    writefln("%s functions, %s structs, %s callbacks, %s enums, %s constants, %s typedefs, %s interfaces", fns,
            model.structs.length, model.callbacks.length, model.enums.length, model.consts.length,
            model.typedefs.length, model.interfaces.length);
    return 0;
}

/// Pipes `text` through dfmt.
string format(string dfmt, string text)
{
    import std.process : pipeProcess, Redirect, wait;

    auto p = pipeProcess([dfmt], Redirect.stdin | Redirect.stdout);
    p.stdin.write(text);
    p.stdin.close();
    string o;
    foreach (chunk; p.stdout.byChunk(1 << 16))
        o ~= cast(const(char)[]) chunk;
    const rc = wait(p.pid);
    if (rc != 0)
        throw new Exception("dfmt failed");
    return o;
}
