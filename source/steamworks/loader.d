/// Runtime loading of the Steamworks library.
///
/// With the dub configuration "dynamic" (version `SteamworksDynamic`) every
/// flat API function is a pointer, and nothing links against libsteam_api:
/// call `loadSteamworks` before using the API. With the "linked"
/// configuration the functions are linked directly and `loadSteamworks`
/// merely reports success, so the same code works with either.
module steamworks.loader;

import steamworks.raw.symbols;

/// Outcome of `loadSteamworks`.
enum SteamworksLoadStatus
{
    /// Every function was bound (or the library is linked).
    success,
    /// The library could not be opened; see `steamworksLoadError`.
    libraryNotFound,
    /// The library opened but lacks some functions (an older SDK); their
    /// pointers are null and the rest are usable. See `steamworksMissingSymbolCount`.
    missingSymbols,
}

version (Windows)
{
    version (Win64)
        private enum string libraryName = "steam_api64.dll";
    else
        private enum string libraryName = "steam_api.dll";
}
else version (OSX)
    private enum string libraryName = "libsteam_api.dylib";
else
    private enum string libraryName = "libsteam_api.so";

/// File name of the Steamworks library on this platform.
enum string steamworksLibraryName = libraryName;

version (SteamworksDynamic)
{
    version (Windows)
    {
        import core.sys.windows.winbase : FreeLibrary, GetLastError, GetProcAddress, LoadLibraryA;
        import core.sys.windows.windef : HMODULE;

        private __gshared HMODULE handle;
    }
    else version (Posix)
    {
        import core.sys.posix.dlfcn : dlclose, dlerror, dlopen, dlsym, RTLD_LAZY, RTLD_LOCAL;

        private __gshared void* handle;
    }
    else
        static assert(false, "steamworks: no dynamic loader for this platform");

    private __gshared SteamworksLoadStatus lastStatus = SteamworksLoadStatus.libraryNotFound;
    private __gshared size_t missingCount;
    private enum size_t errorCapacity = 512;
    private __gshared char[errorCapacity] errorBuffer = 0;
    private __gshared size_t errorLength;

    /// Loads the Steamworks library and binds every function.
    ///
    /// `libraryPath` may name the library file or be null, in which case
    /// `steamworksLibraryName` is looked up next to the executable first and
    /// then through the platform's normal library search. Calling it again
    /// while loaded returns the earlier status. Not thread-safe: load once at
    /// startup, before other threads use the API.
    SteamworksLoadStatus loadSteamworks(const(char)* libraryPath = null) nothrow @nogc
    {
        if (handle)
            return lastStatus;
        errorLength = 0;
        if (libraryPath)
            handle = open(libraryPath);
        else
        {
            char[4096] buf = void;
            if (auto p = besideExecutable(buf[], steamworksLibraryName))
                handle = open(p);
            if (!handle)
                handle = open(steamworksLibraryName.ptr);
        }
        if (!handle)
        {
            recordError();
            return lastStatus = SteamworksLoadStatus.libraryNotFound;
        }
        missingCount = bindSteamworksSymbols((void** slot, const(char)* name) nothrow @nogc {
            *slot = symbol(name);
            return *slot !is null;
        });
        return lastStatus = missingCount ? SteamworksLoadStatus.missingSymbols : SteamworksLoadStatus.success;
    }

    /// ditto
    SteamworksLoadStatus loadSteamworks(string libraryPath) nothrow @nogc
    {
        char[4096] buf = void;
        if (libraryPath.length >= buf.length)
        {
            setError("library path too long");
            return SteamworksLoadStatus.libraryNotFound;
        }
        buf[0 .. libraryPath.length] = libraryPath[];
        buf[libraryPath.length] = 0;
        return loadSteamworks(buf.ptr);
    }

    /// Unloads the library and resets every function pointer to null. Call
    /// only after `SteamAPI_Shutdown`, with no other thread using the API.
    void unloadSteamworks() nothrow @nogc
    {
        if (!handle)
            return;
        bindSteamworksSymbols((void** slot, const(char)*) nothrow @nogc { *slot = null; return true; });
        version (Windows)
            FreeLibrary(handle);
        else
            dlclose(handle);
        handle = null;
        missingCount = 0;
        lastStatus = SteamworksLoadStatus.libraryNotFound;
    }

    /// Whether the library is loaded.
    bool isSteamworksLoaded() nothrow @nogc
    {
        return handle !is null;
    }

    /// How many functions the loaded library lacks.
    size_t steamworksMissingSymbolCount() nothrow @nogc
    {
        return missingCount;
    }

    /// The loader's message for the last failure to open the library, or an
    /// empty string.
    const(char)[] steamworksLoadError() nothrow @nogc
    {
        return errorBuffer[0 .. errorLength];
    }

    private auto open(const(char)* path) nothrow @nogc
    {
        version (Windows)
            return LoadLibraryA(path);
        else
            return dlopen(path, RTLD_LAZY | RTLD_LOCAL);
    }

    private void* symbol(const(char)* name) nothrow @nogc
    {
        version (Windows)
            return cast(void*) GetProcAddress(handle, name);
        else
            return dlsym(handle, name);
    }

    private void setError(const(char)[] msg) nothrow @nogc
    {
        errorLength = msg.length < errorBuffer.length ? msg.length : errorBuffer.length;
        errorBuffer[0 .. errorLength] = msg[0 .. errorLength];
    }

    private void recordError() nothrow @nogc
    {
        version (Windows)
        {
            import core.stdc.stdio : snprintf;

            const n = snprintf(errorBuffer.ptr, errorBuffer.length,
                    "LoadLibrary failed (error %lu)", cast(uint) GetLastError());
            // snprintf returns the untruncated length and always terminates.
            errorLength = n < 0 ? 0 : n < errorCapacity ? n : errorCapacity - 1;
        }
        else
        {
            import core.stdc.string : strlen;

            const e = dlerror();
            setError(e ? e[0 .. strlen(e)] : "dlopen failed");
        }
    }

    /// Writes `<directory of the executable>/<name>` into `buf`; null if unknown.
    private const(char)* besideExecutable(char[] buf, string name) nothrow @nogc
    {
        size_t n;
        version (OSX)
        {
            import core.stdc.string : strlen;

            uint size = cast(uint) buf.length;
            if (_NSGetExecutablePath(buf.ptr, &size) != 0)
                return null;
            n = strlen(buf.ptr);
        }
        else version (linux)
        {
            import core.sys.posix.unistd : readlink;

            const r = readlink("/proc/self/exe", buf.ptr, buf.length);
            if (r <= 0 || r >= buf.length)
                return null;
            n = r;
        }
        else
            return null;
        while (n && buf[n - 1] != '/')
            --n;
        if (!n || n + name.length + 1 > buf.length)
            return null;
        buf[n .. n + name.length] = name[];
        buf[n + name.length] = 0;
        return buf.ptr;
    }

    version (OSX) private extern (C) int _NSGetExecutablePath(char* buf, uint* bufsize) nothrow @nogc;
}
else
{
    /// The library is linked: always succeeds.
    SteamworksLoadStatus loadSteamworks(const(char)*  = null) nothrow @nogc
    {
        return SteamworksLoadStatus.success;
    }

    /// ditto
    SteamworksLoadStatus loadSteamworks(string) nothrow @nogc
    {
        return SteamworksLoadStatus.success;
    }

    /// The library is linked: nothing to unload.
    void unloadSteamworks() nothrow @nogc
    {
    }

    /// The library is linked: always true.
    bool isSteamworksLoaded() nothrow @nogc
    {
        return true;
    }

    /// The library is linked: always 0.
    size_t steamworksMissingSymbolCount() nothrow @nogc
    {
        return 0;
    }

    /// The library is linked: always empty.
    const(char)[] steamworksLoadError() nothrow @nogc
    {
        return null;
    }
}

version (SteamworksDynamic) unittest
{
    assert(loadSteamworks("/nonexistent/libsteam_api_missing") == SteamworksLoadStatus.libraryNotFound);
    assert(!isSteamworksLoaded());
    assert(steamworksLoadError().length > 0);
}
