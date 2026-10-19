/// Callback and call-result dispatch on top of Steam's manual dispatch API.
///
/// A `CallbackDispatcher` owns the per-frame pump: `runFrame` calls
/// `SteamAPI_ManualDispatch_RunFrame`, drains the pipe's queued callbacks,
/// hands each to the handlers registered for its struct type, and fetches the
/// results of completed asynchronous calls (`SteamAPICall_t`) for the
/// handlers waiting on them. Manual dispatch must be selected, which
/// `steamInit` and `steamGameServerInit` do by default.
///
/// ---
/// steamInitOrThrow();
/// auto steam = CallbackDispatcher.forClient();
///
/// auto overlay = steam.register((ref const GameOverlayActivated_t e) {
///     paused = e.m_bActive != 0;
/// });
///
/// steam.call!SteamAPI_ISteamUserStats_FindLeaderboard(SteamUserStats(), "Feet Traveled")
///     .then((ref const LeaderboardFindResult_t r, bool ioFailure) {
///         if (!ioFailure && r.m_bLeaderboardFound)
///             board = r.m_hSteamLeaderboard;
///     });
///
/// while (running)
/// {
///     steam.runFrame();
///     // ...
/// }
/// steam.unregister(overlay);
/// ---
///
/// Handlers may register and unregister handlers (including themselves) and
/// cancel call results while being called. `runFrame` allocates nothing from
/// the GC; registration stores handlers in `malloc` memory that the GC scans.
/// `NogcCallbackDispatcher` requires `nothrow @nogc` handlers, which makes
/// `runFrame` itself `nothrow @nogc`.
///
/// A game server has its own pipe: use `CallbackDispatcher.forGameServer()`
/// (one dispatcher per pipe when a process is both client and server).
///
/// The callback source is an interface, so tests and tools can feed a
/// dispatcher synthetic callbacks instead of Steam's.
module steamworks.dispatch;

import core.atomic : atomicOp;
import core.memory : GC;
import core.stdc.stdlib : free, malloc, realloc;
import core.stdc.string : memcpy, memset;
import std.traits : FunctionAttribute, functionAttributes, FunctionTypeOf, getUDAs, isCallable,
    isDelegate, isFunctionPointer, Parameters, Unqual;

import steamworks.raw.attributes : SteamCallResult;
import steamworks.raw.callbacks : SteamAPICallCompleted_t;
import steamworks.raw.consts : k_uAPICallInvalid;
import steamworks.raw.steam_api;
import steamworks.raw.structs : CallbackMsg_t;
import steamworks.raw.types : HSteamPipe, SteamAPICall_t;

/// Whether `T` is a callback or call-result struct (it has a `k_iCallback`).
enum bool isSteamCallback(T) = is(T == struct) && is(typeof(T.k_iCallback) : int);

/// The struct an asynchronous flat function completes with, from its
/// `SteamCallResult` attribute:
/// ---
/// static assert(is(CallResultOf!SteamAPI_ISteamUserStats_FindLeaderboard == LeaderboardFindResult_t));
/// ---
template CallResultOf(alias fn)
{
    private alias udas = getUDAs!(fn, SteamCallResult);
    static assert(udas.length == 1, __traits(identifier, fn) ~ " has no SteamCallResult attribute");
    alias CallResultOf = typeof(udas[0]).Result;
}

/// The manual-dispatch operations a dispatcher needs, one call each.
/// `manualDispatchSource` forwards them to Steam; tests implement them to
/// inject synthetic callbacks.
interface CallbackSource
{
    /// `SteamAPI_ManualDispatch_RunFrame`: lets Steam do its per-frame work.
    void runFrame(HSteamPipe pipe) nothrow @nogc;

    /// `SteamAPI_ManualDispatch_GetNextCallback`: fetches the next queued
    /// callback. Each callback fetched is released with `freeLastCallback`
    /// before the next is fetched.
    bool nextCallback(HSteamPipe pipe, out CallbackMsg_t msg) nothrow @nogc;

    /// `SteamAPI_ManualDispatch_FreeLastCallback`: releases the callback
    /// `nextCallback` returned.
    void freeLastCallback(HSteamPipe pipe) nothrow @nogc;

    /// `SteamAPI_ManualDispatch_GetAPICallResult`: copies the result of a
    /// completed call into `buffer`. Returns false when no result is
    /// available; `failed` reports an I/O failure.
    bool apiCallResult(HSteamPipe pipe, SteamAPICall_t call, void[] buffer, int expectedCallback, out bool failed) nothrow @nogc;
}

/// `CallbackSource` backed by Steam's manual dispatch functions.
final class ManualDispatchSource : CallbackSource
{
    /// Forwards to `SteamAPI_ManualDispatch_RunFrame`.
    override void runFrame(HSteamPipe pipe) nothrow @nogc
    {
        SteamAPI_ManualDispatch_RunFrame(pipe);
    }

    /// Forwards to `SteamAPI_ManualDispatch_GetNextCallback`.
    override bool nextCallback(HSteamPipe pipe, out CallbackMsg_t msg) nothrow @nogc
    {
        return SteamAPI_ManualDispatch_GetNextCallback(pipe, &msg);
    }

    /// Forwards to `SteamAPI_ManualDispatch_FreeLastCallback`.
    override void freeLastCallback(HSteamPipe pipe) nothrow @nogc
    {
        SteamAPI_ManualDispatch_FreeLastCallback(pipe);
    }

    /// Forwards to `SteamAPI_ManualDispatch_GetAPICallResult`.
    override bool apiCallResult(HSteamPipe pipe, SteamAPICall_t call, void[] buffer,
            int expectedCallback, out bool failed) nothrow @nogc
    {
        return SteamAPI_ManualDispatch_GetAPICallResult(pipe, call, buffer.ptr,
                cast(int) buffer.length, expectedCallback, &failed);
    }
}

private __gshared ManualDispatchSource sharedManualDispatch = new ManualDispatchSource;

/// The `CallbackSource` that talks to Steam. Dispatchers created without a
/// source use it.
CallbackSource manualDispatchSource() nothrow @nogc
{
    return sharedManualDispatch;
}

/// Identifies a callback handler registration; pass it to
/// `BasicCallbackDispatcher.unregister`. The default value identifies nothing.
struct CallbackToken
{
    private ulong id;

    /// Whether the token came from a successful registration.
    bool opCast(T : bool)() const @safe pure nothrow @nogc
    {
        return id != 0;
    }
}

/// Identifies a pending call result; pass it to
/// `BasicCallbackDispatcher.cancel`. The default value identifies nothing.
struct CallResultToken
{
    private ulong id;
    /// The asynchronous call being waited on.
    SteamAPICall_t call = k_uAPICallInvalid;

    /// Whether the token came from a successful registration.
    bool opCast(T : bool)() const @safe pure nothrow @nogc
    {
        return id != 0;
    }
}

private shared ulong lastTokenId;

private ulong newTokenId() nothrow @nogc
{
    return atomicOp!"+="(lastTokenId, 1);
}

/// Callback id that matches every callback (raw "catch-all" handlers).
private enum int anyCallback = int.min;

/// Pumps callbacks and call results for one Steam pipe. Use the aliases
/// `CallbackDispatcher` (handlers of any kind) and `NogcCallbackDispatcher`
/// (`nothrow @nogc` handlers only).
///
/// The dispatcher cannot be copied, since it owns its handler storage; keep
/// it in a variable, field or global, and move it if needed. A
/// default-initialized dispatcher has pipe 0 and does nothing until `pipe`
/// is set, so handlers can be registered before Steam starts.
///
/// Handlers receive the callback struct by `ref const`; it is only valid
/// during the call. Handlers for a callback run in registration order.
///
/// With `CallbackDispatcher`, an exception thrown by a handler does not stop
/// the other handlers of the same callback; once they have run, the
/// exception (chained with any others) propagates out of `runFrame`, and
/// callbacks still queued are delivered by the next `runFrame`.
struct BasicCallbackDispatcher(bool nogcHandlers)
{
    static if (nogcHandlers)
    {
        /// Handler for callback struct `T`.
        alias CallbackHandler(T) = void delegate(ref const T) nothrow @nogc;
        /// Handler for a call result of type `T`. `ioFailure` is true when the
        /// call failed (Steam reported an I/O failure, no result was available,
        /// or the result has a different type than `T`); `T` is then
        /// unreliable or all zero.
        alias CallResultHandler(T) = void delegate(ref const T, bool ioFailure) nothrow @nogc;
        /// Handler receiving callbacks as Steam delivers them.
        alias RawHandler = void delegate(ref const CallbackMsg_t) nothrow @nogc;
        private alias Thunk = void function(ref const Entry, ref const CallbackMsg_t, const(void)*, size_t, bool) nothrow @nogc;
    }
    else
    {
        /// Handler for callback struct `T`.
        alias CallbackHandler(T) = void delegate(ref const T);
        /// Handler for a call result of type `T`. `ioFailure` is true when the
        /// call failed (Steam reported an I/O failure, no result was available,
        /// or the result has a different type than `T`); `T` is then
        /// unreliable or all zero.
        alias CallResultHandler(T) = void delegate(ref const T, bool ioFailure);
        /// Handler receiving callbacks as Steam delivers them.
        alias RawHandler = void delegate(ref const CallbackMsg_t);
        private alias Thunk = void function(ref const Entry, ref const CallbackMsg_t, const(void)*, size_t, bool);
    }

    /// The Steam pipe to pump; 0 (the default) makes `runFrame` do nothing.
    HSteamPipe pipe;

    /// Where callbacks come from; null means `manualDispatchSource()`.
    CallbackSource source;

    private EntryList!Entry callbacks;
    private EntryList!Entry callResults;
    private ubyte* resultBuffer;
    private size_t resultBufferSize;
    private bool dispatching;
    private bool needsCompaction;

    /// Creates a dispatcher for `pipe`, reading callbacks from `source`
    /// (Steam's manual dispatch when null).
    this(HSteamPipe pipe, CallbackSource source = null) nothrow @nogc
    {
        this.pipe = pipe;
        this.source = source;
    }

    @disable this(this);

    ~this() nothrow @nogc
    {
        callbacks.release();
        callResults.release();
        free(resultBuffer);
    }

    /// A dispatcher for the game's client pipe (`SteamAPI_GetHSteamPipe`).
    /// Create it after `steamInit`; before then (or with the library not
    /// loaded) its pipe is 0.
    static BasicCallbackDispatcher forClient() nothrow @nogc
    {
        version (SteamworksDynamic)
            if (SteamAPI_GetHSteamPipe is null)
                return BasicCallbackDispatcher.init;
        return BasicCallbackDispatcher(SteamAPI_GetHSteamPipe());
    }

    /// A dispatcher for the game server pipe (`SteamGameServer_GetHSteamPipe`).
    /// Create it after `steamGameServerInit`.
    static BasicCallbackDispatcher forGameServer() nothrow @nogc
    {
        version (SteamworksDynamic)
            if (SteamGameServer_GetHSteamPipe is null)
                return BasicCallbackDispatcher.init;
        return BasicCallbackDispatcher(SteamGameServer_GetHSteamPipe());
    }

    /// Registers `handler` for callback struct `T`. The handler is a delegate
    /// or function pointer taking `ref const T`; `T` may be given explicitly or
    /// inferred from the handler's parameter:
    /// ---
    /// d.register!PersonaStateChange_t((ref e) { ... });
    /// d.register((ref const PersonaStateChange_t e) { ... });
    /// d.register(&onPersonaStateChange);
    /// ---
    /// Returns the token for `unregister`. A handler registered while a
    /// callback is being dispatched first runs for the next callback.
    CallbackToken register(T)(CallbackHandler!T handler) if (isSteamCallback!T)
    {
        return addCallback!(T, typeof(handler))(handler);
    }

    /// ditto
    CallbackToken register(T, F)(F handler)
            if (isSteamCallback!T && isCallable!F && !is(F : CallbackHandler!T))
    {
        return addCallback!(T, F)(handler);
    }

    /// ditto
    CallbackToken register(F)(F handler) if (isCallable!F)
    {
        static assert(Parameters!F.length == 1 && isSteamCallback!(Unqual!(Parameters!F[0])),
                "a callback handler takes one callback struct, as (ref const T)");
        return addCallback!(Unqual!(Parameters!F[0]), F)(handler);
    }

    /// Registers `handler` for every callback with id `callbackId`, or for
    /// every callback at all, receiving Steam's `CallbackMsg_t` as is
    /// (`m_pubParam` points to `m_cubParam` bytes of the callback struct).
    /// Useful for logging or for callbacks without a binding.
    CallbackToken registerRaw(int callbackId, RawHandler handler)
    {
        return add(callbacks, callbackId, k_uAPICallInvalid, 0, handler.ptr, cast(void*) handler.funcptr, &rawThunk);
    }

    /// ditto
    CallbackToken registerRaw(RawHandler handler)
    {
        return registerRaw(anyCallback, handler);
    }

    /// Removes a callback handler. Returns false when the token is unknown
    /// (never registered, already unregistered, or from another dispatcher).
    /// Safe to call from any handler, including the one being removed; a
    /// handler removed during dispatch is not called again.
    bool unregister(CallbackToken token) nothrow @nogc
    {
        return remove(callbacks, token.id);
    }

    /// Waits for the result of asynchronous call `call`, which completes
    /// with struct `T`; `handler` takes `(ref const T result, bool ioFailure)`
    /// and runs once. `T` may be given explicitly or inferred from the
    /// handler.
    ///
    /// An invalid handle (`k_uAPICallInvalid`, which flat functions return
    /// when the call could not be started) registers nothing and returns an
    /// invalid token: the handler is never called.
    ///
    /// Several handlers may wait on the same call; the result is fetched once
    /// and passed to each.
    CallResultToken callResult(T)(SteamAPICall_t call, CallResultHandler!T handler)
            if (isSteamCallback!T)
    {
        return addCallResult!(T, typeof(handler))(call, handler);
    }

    /// ditto
    CallResultToken callResult(T, F)(SteamAPICall_t call, F handler)
            if (isSteamCallback!T && isCallable!F && !is(F : CallResultHandler!T))
    {
        return addCallResult!(T, F)(call, handler);
    }

    /// ditto
    CallResultToken callResult(F)(SteamAPICall_t call, F handler) if (isCallable!F)
    {
        static assert(Parameters!F.length == 2 && isSteamCallback!(Unqual!(Parameters!F[0]))
                && is(Parameters!F[1] == bool), "a call result handler takes (ref const T result, bool ioFailure)");
        return addCallResult!(Unqual!(Parameters!F[0]), F)(call, handler);
    }

    /// Calls asynchronous flat function `fn` with `args` and returns a
    /// `PendingCall` whose `then` registers the handler for its result type,
    /// taken from `fn`'s `SteamCallResult` attribute:
    /// ---
    /// d.call!SteamAPI_ISteamUserStats_FindLeaderboard(SteamUserStats(), "Feet Traveled")
    ///     .then((ref r, ioFailure) { ... });
    /// ---
    ///
    /// The arguments take `fn`'s exact parameter list, so they convert as in a
    /// direct call (string literals to `const(char)*`, `ref` and `out`
    /// parameters kept).
    template call(alias fn)
    {
        static if (is(FunctionTypeOf!fn Params == __parameters))
        {
            /// ditto
            PendingCall!(CallResultOf!fn) call(Params args) return
            {
                return PendingCall!(CallResultOf!fn)(&this, fn(args));
            }
        }
    }

    /// An asynchronous call made with `call`, waiting for a handler.
    struct PendingCall(T)
    {
        private BasicCallbackDispatcher* dispatcher;

        /// The call's handle; `k_uAPICallInvalid` if it could not be started.
        SteamAPICall_t handle;

        /// Registers the handler for the call's result, as `callResult` does.
        CallResultToken then(CallResultHandler!T handler)
        {
            return dispatcher.callResult!T(handle, handler);
        }

        /// ditto
        CallResultToken then(F)(F handler) if (isCallable!F && !is(F : CallResultHandler!T))
        {
            return dispatcher.callResult!(T, F)(handle, handler);
        }
    }

    /// Stops waiting for a call result; its handler will not run. Returns
    /// false when the token is not pending (unknown, cancelled, or already
    /// delivered). Safe to call from any handler.
    bool cancel(CallResultToken token) nothrow @nogc
    {
        return remove(callResults, token.id);
    }

    /// Whether the call result is still waiting to be delivered.
    bool isPending(CallResultToken token) const nothrow @nogc
    {
        return token.id && callResults.find(token.id) != size_t.max;
    }

    /// Number of registered callback handlers.
    size_t handlerCount() const nothrow @nogc
    {
        return callbacks.live();
    }

    /// Number of call results waiting to be delivered.
    size_t pendingCallResultCount() const nothrow @nogc
    {
        return callResults.live();
    }

    /// Unregisters every handler and cancels every pending call result.
    void clear() nothrow @nogc
    {
        callbacks.removeAll();
        callResults.removeAll();
        compactLater();
    }

    /// Lets Steam do its per-frame work and delivers every queued callback
    /// and completed call result. Call it once per frame on the thread that
    /// owns the dispatcher. Does nothing when `pipe` is 0, and when called
    /// from one of this dispatcher's handlers.
    void runFrame()
    {
        if (dispatching || pipe == 0)
            return;
        CallbackSource src = source ? source : manualDispatchSource();
        dispatching = true;
        scope (exit)
        {
            dispatching = false;
            if (needsCompaction)
            {
                needsCompaction = false;
                callbacks.compact();
                callResults.compact();
            }
        }
        src.runFrame(pipe);
        CallbackMsg_t msg;
        while (src.nextCallback(pipe, msg))
        {
            scope (exit)
                src.freeLastCallback(pipe);
            deliver(src, msg);
        }
    }

private:
    static struct Entry
    {
        ulong token;
        int callbackId;
        SteamAPICall_t call;
        size_t resultSize;
        void* context;
        void* fn;
        Thunk thunk;
    }

    CallbackToken addCallback(T, F)(F handler)
    {
        checkHandler!F();
        static if (isDelegate!F)
            return add(callbacks, T.k_iCallback, k_uAPICallInvalid, T.sizeof, handler.ptr,
                    cast(void*) handler.funcptr, &callbackThunk!(T, F));
        else
            return add(callbacks, T.k_iCallback, k_uAPICallInvalid, T.sizeof, null,
                    cast(void*) handler, &callbackThunk!(T, F));
    }

    CallResultToken addCallResult(T, F)(SteamAPICall_t call, F handler)
    {
        checkHandler!F();
        if (call == k_uAPICallInvalid)
            return CallResultToken.init;
        static if (isDelegate!F)
            const token = add(callResults, T.k_iCallback, call, T.sizeof, handler.ptr,
                    cast(void*) handler.funcptr, &callResultThunk!(T, F));
        else
            const token = add(callResults, T.k_iCallback, call, T.sizeof, null,
                    cast(void*) handler, &callResultThunk!(T, F));
        return CallResultToken(token.id, token.id ? call : k_uAPICallInvalid);
    }

    static void checkHandler(F)()
    {
        static assert(isDelegate!F || isFunctionPointer!F,
                "handlers are delegates or function pointers; got " ~ F.stringof);
        static if (nogcHandlers)
            static assert((functionAttributes!F & (FunctionAttribute.nothrow_ | FunctionAttribute.nogc)) == (
                    FunctionAttribute.nothrow_ | FunctionAttribute.nogc),
                    "NogcCallbackDispatcher handlers must be nothrow @nogc; got " ~ F.stringof);
    }

    CallbackToken add(ref EntryList!Entry list, int callbackId, SteamAPICall_t call, size_t resultSize,
            void* context, void* fn, Thunk thunk) nothrow @nogc
    {
        const id = newTokenId();
        if (!list.append(Entry(id, callbackId, call, resultSize, context, fn, thunk)))
            return CallbackToken.init;
        return CallbackToken(id);
    }

    bool remove(ref EntryList!Entry list, ulong id) nothrow @nogc
    {
        const i = id ? list.find(id) : size_t.max;
        if (i == size_t.max)
            return false;
        list[i].token = 0;
        compactLater();
        return true;
    }

    void compactLater() nothrow @nogc
    {
        if (dispatching)
        {
            needsCompaction = true;
            return;
        }
        callbacks.compact();
        callResults.compact();
    }

    void deliver(CallbackSource src, ref const CallbackMsg_t msg)
    {
        Exception pending;
        if (msg.m_iCallback == SteamAPICallCompleted_t.k_iCallback && msg.m_pubParam !is null
                && msg.m_cubParam >= SteamAPICallCompleted_t.sizeof)
            deliverCallResult(src, *cast(const(SteamAPICallCompleted_t)*) msg.m_pubParam, msg, pending);

        const size = msg.m_cubParam > 0 ? cast(size_t) msg.m_cubParam : 0;
        // Handlers registered from a handler wait for the next callback.
        const n = callbacks.length;
        foreach (i; 0 .. n)
        {
            const e = callbacks[i];
            if (e.token && (e.callbackId == msg.m_iCallback || e.callbackId == anyCallback))
                invoke(e, msg, msg.m_pubParam, size, false, pending);
        }
        static if (!nogcHandlers)
            if (pending)
                throw pending;
    }

    void deliverCallResult(CallbackSource src, ref const SteamAPICallCompleted_t done,
            ref const CallbackMsg_t msg, ref Exception pending)
    {
        const call = done.m_hAsyncCall;
        size_t needed = done.m_cubParam;
        bool claimed;
        foreach (i; 0 .. callResults.length)
        {
            const e = callResults[i];
            if (e.token && e.call == call)
            {
                claimed = true;
                if (e.resultSize > needed)
                    needed = e.resultSize;
            }
        }
        // Results nobody waits for stay with Steam.
        if (!claimed)
            return;

        bool failed;
        bool fetched;
        if (reserveResultBuffer(needed))
        {
            memset(resultBuffer, 0, needed);
            fetched = src.apiCallResult(pipe, call, resultBuffer[0 .. done.m_cubParam], done.m_iCallback, failed);
        }
        const n = callResults.length;
        foreach (i; 0 .. n)
        {
            if (!callResults[i].token || callResults[i].call != call)
                continue;
            const e = callResults[i];
            callResults[i].token = 0;
            needsCompaction = true;
            const usable = fetched && e.callbackId == done.m_iCallback;
            invoke(e, msg, usable ? resultBuffer : null, done.m_cubParam, !usable || failed, pending);
        }
    }

    bool reserveResultBuffer(size_t size) nothrow @nogc
    {
        if (size <= resultBufferSize)
            return true;
        auto p = cast(ubyte*) realloc(resultBuffer, size);
        if (p is null)
            return false;
        resultBuffer = p;
        resultBufferSize = size;
        return true;
    }

    static void invoke(ref const Entry e, ref const CallbackMsg_t msg, const(void)* data, size_t size,
            bool failure, ref Exception pending)
    {
        static if (nogcHandlers)
        {
            cast(void) pending;
            e.thunk(e, msg, data, size, failure);
        }
        else
        {
            try
                e.thunk(e, msg, data, size, failure);
            catch (Exception ex)
                pending = pending is null ? ex : cast(Exception) Throwable.chainTogether(pending, ex);
        }
    }

    static void callHandler(F, Args...)(ref const Entry e, ref Args args)
    {
        static if (isDelegate!F)
        {
            F dg;
            dg.ptr = cast(void*) e.context;
            dg.funcptr = cast(typeof(dg.funcptr)) e.fn;
            dg(args);
        }
        else
            (cast(F) e.fn)(args);
    }

    /// Points at the struct in `data`, or copies what there is into
    /// `scratch` (zero-filling the rest) when `data` is missing or short.
    static const(T)* view(T)(const(void)* data, size_t size, ref T scratch) @trusted
    {
        if (data !is null && size >= T.sizeof)
            return cast(const(T)*) data;
        scratch = T.init;
        if (data !is null)
            memcpy(&scratch, data, size);
        return &scratch;
    }

    static void callbackThunk(T, F)(ref const Entry e, ref const CallbackMsg_t, const(void)* data, size_t size, bool)
    {
        T scratch = void;
        auto p = view!T(data, size, scratch);
        callHandler!F(e, *p);
    }

    static void callResultThunk(T, F)(ref const Entry e, ref const CallbackMsg_t, const(void)* data,
            size_t size, bool failure)
    {
        T scratch = void;
        auto p = view!T(data, size, scratch);
        callHandler!F(e, *p, failure);
    }

    static void rawThunk(ref const Entry e, ref const CallbackMsg_t msg, const(void)*, size_t, bool)
    {
        callHandler!RawHandler(e, msg);
    }
}

/// Dispatcher accepting any handler; exceptions from handlers propagate out
/// of `runFrame` (see `BasicCallbackDispatcher`).
alias CallbackDispatcher = BasicCallbackDispatcher!false;

/// Dispatcher accepting only `nothrow @nogc` handlers, so that `runFrame` is
/// `nothrow @nogc`.
alias NogcCallbackDispatcher = BasicCallbackDispatcher!true;

/// Growable array in `malloc` memory that the GC scans (handler entries hold
/// delegate contexts). Removed entries have token 0 until `compact`.
private struct EntryList(E)
{
    private E* data;
    private size_t count;
    private size_t capacity;

    @disable this(this);

    size_t length() const nothrow @nogc
    {
        return count;
    }

    ref inout(E) opIndex(size_t i) inout nothrow @nogc
    {
        assert(i < count);
        return data[i];
    }

    bool append(E e) nothrow @nogc
    {
        if (count == capacity)
        {
            const newCapacity = capacity ? capacity * 2 : 8;
            auto p = cast(E*) malloc(newCapacity * E.sizeof);
            if (p is null)
                return false;
            if (count)
                memcpy(p, data, count * E.sizeof);
            GC.addRange(p, newCapacity * E.sizeof);
            // The old block stays registered until the new one is, so the
            // contexts are always visible to the GC.
            if (data !is null)
            {
                GC.removeRange(data);
                free(data);
            }
            data = p;
            capacity = newCapacity;
        }
        data[count++] = e;
        return true;
    }

    size_t find(ulong token) const nothrow @nogc
    {
        foreach (i; 0 .. count)
            if (data[i].token == token)
                return i;
        return size_t.max;
    }

    size_t live() const nothrow @nogc
    {
        size_t n;
        foreach (i; 0 .. count)
            if (data[i].token)
                ++n;
        return n;
    }

    void removeAll() nothrow @nogc
    {
        foreach (i; 0 .. count)
            data[i].token = 0;
    }

    void compact() nothrow @nogc
    {
        size_t kept;
        foreach (i; 0 .. count)
            if (data[i].token)
                data[kept++] = data[i];
        if (kept < count)
            memset(data + kept, 0, (count - kept) * E.sizeof);
        count = kept;
    }

    void release() nothrow @nogc
    {
        if (data is null)
            return;
        GC.removeRange(data);
        free(data);
        data = null;
        count = capacity = 0;
    }
}

version (unittest)
{
    import steamworks.raw.callbacks : GameOverlayActivated_t, LeaderboardFindResult_t,
        NumberOfCurrentPlayers_t, PersonaStateChange_t;
    import steamworks.raw.isteamuserstats : SteamAPI_ISteamUserStats_FindLeaderboard;
    import steamworks.raw.types : HSteamUser;

    /// Feeds a dispatcher queued messages and call results, checking that
    /// the dispatcher follows the manual dispatch protocol.
    private final class FakeSource : CallbackSource
    {
        static struct Result
        {
            SteamAPICall_t call;
            int callbackId;
            ubyte[] bytes;
            bool ioFailure;
        }

        CallbackMsg_t[] queue;
        size_t next;
        Result[] results;
        HSteamPipe[16] pipeLog;
        size_t pipeCount;
        int frames, gets, frees, fetches;
        int lastExpected = -1;
        size_t lastFetchSize;
        bool outstanding;

        void push(T)(T value, HSteamUser user = 1)
        {
            pushBytes(T.k_iCallback, (cast(ubyte*)&value)[0 .. T.sizeof].dup, user);
        }

        void pushBytes(int id, ubyte[] bytes, HSteamUser user = 1)
        {
            CallbackMsg_t m;
            m.m_hSteamUser = user;
            m.m_iCallback = id;
            m.m_pubParam = bytes.ptr;
            m.m_cubParam = cast(int) bytes.length;
            queue ~= m;
        }

        /// Queues the completion of `call` with result `value`.
        void complete(T)(SteamAPICall_t call, T value, bool ioFailure = false)
        {
            results ~= Result(call, T.k_iCallback, (cast(ubyte*)&value)[0 .. T.sizeof].dup, ioFailure);
            SteamAPICallCompleted_t done;
            done.m_hAsyncCall = call;
            done.m_iCallback = T.k_iCallback;
            done.m_cubParam = T.sizeof;
            push(done);
        }

        override void runFrame(HSteamPipe pipe) nothrow @nogc
        {
            ++frames;
            if (pipeCount < pipeLog.length)
                pipeLog[pipeCount++] = pipe;
        }

        override bool nextCallback(HSteamPipe, out CallbackMsg_t msg) nothrow @nogc
        {
            assert(!outstanding, "next callback fetched before the last was freed");
            ++gets;
            if (next == queue.length)
                return false;
            msg = queue[next++];
            outstanding = true;
            return true;
        }

        override void freeLastCallback(HSteamPipe) nothrow @nogc
        {
            assert(outstanding, "freed a callback that was not fetched");
            outstanding = false;
            ++frees;
        }

        override bool apiCallResult(HSteamPipe, SteamAPICall_t call, void[] buffer, int expected, out bool failed) nothrow @nogc
        {
            ++fetches;
            lastExpected = expected;
            lastFetchSize = buffer.length;
            foreach (ref r; results)
            {
                if (r.call != call || r.bytes is null)
                    continue;
                if (r.callbackId != expected || r.bytes.length != buffer.length)
                    return false;
                buffer[] = r.bytes[];
                failed = r.ioFailure;
                r.bytes = null; // a result can be fetched once
                return true;
            }
            return false;
        }

        const(HSteamPipe)[] pipesSeen() const nothrow @nogc
        {
            return pipeLog[0 .. pipeCount];
        }

        bool drained() const nothrow @nogc
        {
            return next == queue.length && !outstanding;
        }
    }

    private PersonaStateChange_t persona(ulong id, int flags = 0)
    {
        PersonaStateChange_t p;
        p.m_ulSteamID = id;
        p.m_nChangeFlags = flags;
        return p;
    }

    private GameOverlayActivated_t overlay(bool active)
    {
        GameOverlayActivated_t o;
        o.m_bActive = active;
        return o;
    }

    private LeaderboardFindResult_t board(ulong handle)
    {
        LeaderboardFindResult_t r;
        r.m_hSteamLeaderboard = handle;
        r.m_bLeaderboardFound = 1;
        return r;
    }

    private void onPersonaFunction(ref const PersonaStateChange_t p)
    {
        functionSeen = p.m_ulSteamID;
    }

    private __gshared ulong functionSeen;

    private __gshared int fakeFindCalls;

    @SteamCallResult!LeaderboardFindResult_t() private SteamAPICall_t fakeFindByName(const(char)* name,
            ref const PersonaStateChange_t extra, out int written) nothrow @nogc
    {
        written = extra.m_nChangeFlags;
        return name[0] == 'F' ? 51 : k_uAPICallInvalid;
    }

    @SteamCallResult!LeaderboardFindResult_t() private SteamAPICall_t fakeFindLeaderboard(int answer)
    {
        ++fakeFindCalls;
        return answer;
    }
}

/// A typed handler receives its callback; other callbacks are not delivered
/// to it and every fetched callback is freed.
unittest
{
    auto src = new FakeSource;
    auto d = CallbackDispatcher(5, src);
    ulong seen;
    int calls;
    d.register!PersonaStateChange_t((ref e) { seen = e.m_ulSteamID; ++calls; });
    src.push(overlay(true));
    src.push(persona(76_561_197_960_287_930UL, 3));
    d.runFrame();
    assert(calls == 1 && seen == 76_561_197_960_287_930UL);
    assert(src.drained && src.frees == 2 && src.frames == 1);
    assert(src.pipesSeen == [5]);
}

/// The callback type can be inferred from a delegate or function pointer.
unittest
{
    auto src = new FakeSource;
    auto d = CallbackDispatcher(1, src);
    bool active;
    d.register((ref const GameOverlayActivated_t e) { active = e.m_bActive != 0; });
    d.register(&onPersonaFunction);
    src.push(overlay(true));
    src.push(persona(42));
    d.runFrame();
    assert(active && functionSeen == 42);
}

/// An explicit type works with a function pointer too.
unittest
{
    auto src = new FakeSource;
    auto d = CallbackDispatcher(1, src);
    d.register!PersonaStateChange_t(&onPersonaFunction);
    src.push(persona(43));
    d.runFrame();
    assert(functionSeen == 43);
}

/// Handlers of one callback run in registration order.
unittest
{
    auto src = new FakeSource;
    auto d = CallbackDispatcher(1, src);
    int[] order;
    // Each delegate gets its own frame holding its index.
    static CallbackDispatcher.CallbackHandler!PersonaStateChange_t appender(int[]* order, int i)
    {
        return (ref e) { *order ~= i; };
    }

    foreach (i; 0 .. 4)
        d.register!PersonaStateChange_t(appender(&order, i));
    src.push(persona(1));
    d.runFrame();
    assert(order == [0, 1, 2, 3]);
    assert(d.handlerCount == 4);
}

/// Unregistering by token stops delivery; unknown tokens are rejected.
unittest
{
    auto src = new FakeSource;
    auto d = CallbackDispatcher(1, src);
    int a, b;
    auto ta = d.register!PersonaStateChange_t((ref e) { ++a; });
    d.register!PersonaStateChange_t((ref e) { ++b; });
    assert(ta);
    assert(d.unregister(ta));
    assert(!d.unregister(ta));
    assert(!d.unregister(CallbackToken.init));
    src.push(persona(1));
    d.runFrame();
    assert(a == 0 && b == 1 && d.handlerCount == 1);
}

/// Tokens of one dispatcher do not remove handlers of another.
unittest
{
    auto client = CallbackDispatcher(1, new FakeSource);
    auto server = CallbackDispatcher(2, new FakeSource);
    auto t = client.register!PersonaStateChange_t((ref e) {});
    server.register!PersonaStateChange_t((ref e) {});
    assert(!server.unregister(t));
    assert(server.handlerCount == 1 && client.unregister(t));
}

/// A handler can unregister itself, and a later handler, while running.
unittest
{
    auto src = new FakeSource;
    auto d = CallbackDispatcher(1, src);
    int first, second, third;
    CallbackToken t1, t2;
    t1 = d.register!PersonaStateChange_t((ref e) { ++first; d.unregister(t1); d.unregister(t2); });
    t2 = d.register!PersonaStateChange_t((ref e) { ++second; });
    d.register!PersonaStateChange_t((ref e) { ++third; });
    src.push(persona(1));
    src.push(persona(2));
    d.runFrame();
    assert(first == 1 && second == 0 && third == 2);
    assert(d.handlerCount == 1);
}

/// A handler registered during dispatch first runs for the next callback.
unittest
{
    auto src = new FakeSource;
    auto d = CallbackDispatcher(1, src);
    ulong[] late;
    bool added;
    d.register!PersonaStateChange_t((ref e) {
        if (!added)
        {
            added = true;
            d.register!PersonaStateChange_t((ref e2) { late ~= e2.m_ulSteamID; });
        }
    });
    src.push(persona(1));
    src.push(persona(2));
    d.runFrame();
    assert(late == [2]);
}

/// Many registrations grow the storage; removals keep the others intact.
unittest
{
    auto src = new FakeSource;
    auto d = CallbackDispatcher(1, src);
    CallbackToken[] tokens;
    int total;
    static CallbackDispatcher.CallbackHandler!PersonaStateChange_t adder(int* total, int i)
    {
        return (ref e) { *total += i; };
    }

    foreach (i; 0 .. 1000)
        tokens ~= d.register!PersonaStateChange_t(adder(&total, i));
    foreach (i; 0 .. 1000)
        if (i % 2)
            assert(d.unregister(tokens[i]));
    assert(d.handlerCount == 500);
    src.push(persona(1));
    d.runFrame();
    int expected;
    foreach (i; 0 .. 1000)
        if (i % 2 == 0)
            expected += i;
    assert(total == expected);
}

/// A call result is fetched with Steam's size and id and delivered once.
unittest
{
    auto src = new FakeSource;
    auto d = CallbackDispatcher(1, src);
    ulong handle;
    bool failure = true;
    int calls;
    auto t = d.callResult!LeaderboardFindResult_t(77, (ref r, ioFailure) {
        handle = r.m_hSteamLeaderboard;
        failure = ioFailure;
        ++calls;
    });
    assert(t && t.call == 77 && d.isPending(t) && d.pendingCallResultCount == 1);
    src.complete(77, board(1234));
    d.runFrame();
    assert(calls == 1 && handle == 1234 && !failure);
    assert(src.lastExpected == LeaderboardFindResult_t.k_iCallback);
    assert(src.lastFetchSize == LeaderboardFindResult_t.sizeof);
    assert(!d.isPending(t) && !d.cancel(t) && d.pendingCallResultCount == 0);
    src.complete(77, board(5678));
    d.runFrame();
    assert(calls == 1);
}

/// The result type can be inferred from the handler.
unittest
{
    auto src = new FakeSource;
    auto d = CallbackDispatcher(1, src);
    int players;
    d.callResult(9, (ref const NumberOfCurrentPlayers_t r, bool) { players = r.m_cPlayers; });
    NumberOfCurrentPlayers_t n;
    n.m_bSuccess = 1;
    n.m_cPlayers = 321;
    src.complete(9, n);
    d.runFrame();
    assert(players == 321);
}

/// Steam's I/O failure flag reaches the handler.
unittest
{
    auto src = new FakeSource;
    auto d = CallbackDispatcher(1, src);
    bool failure;
    d.callResult!LeaderboardFindResult_t(3, (ref r, ioFailure) { failure = ioFailure; });
    src.complete(3, board(1), true);
    d.runFrame();
    assert(failure);
}

/// When no result can be fetched the handler sees a failure and a zero struct.
unittest
{
    auto src = new FakeSource;
    auto d = CallbackDispatcher(1, src);
    bool failure;
    ulong handle = 99;
    d.callResult!LeaderboardFindResult_t(4, (ref r, ioFailure) {
        failure = ioFailure;
        handle = r.m_hSteamLeaderboard;
    });
    SteamAPICallCompleted_t done;
    done.m_hAsyncCall = 4;
    done.m_iCallback = LeaderboardFindResult_t.k_iCallback;
    done.m_cubParam = LeaderboardFindResult_t.sizeof;
    src.push(done);
    d.runFrame();
    assert(failure && handle == 0 && src.fetches == 1);
}

/// A result of another type than the handler expects is a failure.
unittest
{
    auto src = new FakeSource;
    auto d = CallbackDispatcher(1, src);
    bool failure;
    int players = -1;
    d.callResult!NumberOfCurrentPlayers_t(5, (ref r, ioFailure) {
        failure = ioFailure;
        players = r.m_cPlayers;
    });
    src.complete(5, board(1));
    d.runFrame();
    assert(failure && players == 0);
}

/// Several handlers waiting on one call share the single fetch.
unittest
{
    auto src = new FakeSource;
    auto d = CallbackDispatcher(1, src);
    ulong a, b;
    d.callResult!LeaderboardFindResult_t(6, (ref r, io) { a = r.m_hSteamLeaderboard; });
    d.callResult!LeaderboardFindResult_t(6, (ref r, io) { b = r.m_hSteamLeaderboard; });
    src.complete(6, board(11));
    d.runFrame();
    assert(a == 11 && b == 11 && src.fetches == 1);
}

/// A cancelled call result is neither fetched nor delivered.
unittest
{
    auto src = new FakeSource;
    auto d = CallbackDispatcher(1, src);
    bool called;
    auto t = d.callResult!LeaderboardFindResult_t(8, (ref r, io) { called = true; });
    assert(d.cancel(t) && !d.cancel(t));
    src.complete(8, board(1));
    d.runFrame();
    assert(!called && src.fetches == 0);
}

/// A handler can cancel a call result that completes in the same frame.
unittest
{
    auto src = new FakeSource;
    auto d = CallbackDispatcher(1, src);
    bool called;
    auto t = d.callResult!LeaderboardFindResult_t(10, (ref r, io) { called = true; });
    d.register!PersonaStateChange_t((ref e) { assert(d.cancel(t)); });
    src.push(persona(1));
    src.complete(10, board(1));
    d.runFrame();
    assert(!called && d.pendingCallResultCount == 0);
}

/// A call result handler can wait for another call.
unittest
{
    auto src = new FakeSource;
    auto d = CallbackDispatcher(1, src);
    ulong second;
    d.callResult!LeaderboardFindResult_t(20, (ref r, io) {
        d.callResult!LeaderboardFindResult_t(21, (ref r2, io2) { second = r2.m_hSteamLeaderboard; });
    });
    src.complete(20, board(1));
    src.complete(21, board(2));
    d.runFrame();
    assert(second == 2);
}

/// An invalid call handle registers nothing.
unittest
{
    auto d = CallbackDispatcher(1, new FakeSource);
    auto t = d.callResult!LeaderboardFindResult_t(k_uAPICallInvalid, (ref r, io) {});
    assert(!t && t.call == k_uAPICallInvalid && !d.isPending(t) && d.pendingCallResultCount == 0);
}

/// Completions nobody waits for are left with Steam, and
/// SteamAPICallCompleted_t still reaches its own handlers.
unittest
{
    auto src = new FakeSource;
    auto d = CallbackDispatcher(1, src);
    SteamAPICall_t completed;
    d.register!SteamAPICallCompleted_t((ref e) { completed = e.m_hAsyncCall; });
    src.complete(12, board(1));
    d.runFrame();
    assert(completed == 12 && src.fetches == 0);
}

/// A callback shorter than its struct is zero-extended rather than over-read.
unittest
{
    auto src = new FakeSource;
    auto d = CallbackDispatcher(1, src);
    int flags = -1;
    ulong id;
    d.register!PersonaStateChange_t((ref e) { id = e.m_ulSteamID; flags = e.m_nChangeFlags; });
    auto p = persona(0x0102030405060708UL, 77);
    src.pushBytes(PersonaStateChange_t.k_iCallback, (cast(ubyte*)&p)[0 .. 8].dup);
    d.runFrame();
    assert(id == 0x0102030405060708UL && flags == 0);
}

/// Raw handlers see Steam's messages, by id or all of them.
unittest
{
    auto src = new FakeSource;
    auto d = CallbackDispatcher(1, src);
    int[] all;
    int personaSize;
    d.registerRaw((ref const CallbackMsg_t m) { all ~= m.m_iCallback; });
    d.registerRaw(PersonaStateChange_t.k_iCallback, (ref const CallbackMsg_t m) {
        personaSize = m.m_cubParam;
    });
    src.push(overlay(false));
    src.push(persona(1));
    src.pushBytes(999_999, [1, 2, 3]);
    d.runFrame();
    assert(all == [GameOverlayActivated_t.k_iCallback, PersonaStateChange_t.k_iCallback, 999_999]);
    assert(personaSize == PersonaStateChange_t.sizeof);
}

/// A throwing handler does not stop the others; the exception propagates
/// after the callback is freed and the rest of the queue waits a frame.
unittest
{
    import std.exception : collectException;

    auto src = new FakeSource;
    auto d = CallbackDispatcher(1, src);
    int after;
    ulong[] seen;
    d.register!PersonaStateChange_t((ref e) {
        if (e.m_ulSteamID == 1)
            throw new Exception("first");
    });
    d.register!PersonaStateChange_t((ref e) { ++after; seen ~= e.m_ulSteamID; });
    src.push(persona(1));
    src.push(persona(2));
    const ex = collectException(d.runFrame());
    assert(ex !is null && ex.msg == "first");
    assert(after == 1 && !src.outstanding && src.frees == 1);
    d.runFrame();
    assert(seen == [1, 2] && src.drained);
}

/// Exceptions from several handlers are chained.
unittest
{
    import std.exception : collectException;

    auto src = new FakeSource;
    auto d = CallbackDispatcher(1, src);
    d.register!PersonaStateChange_t((ref e) { throw new Exception("a"); });
    d.register!PersonaStateChange_t((ref e) { throw new Exception("b"); });
    src.push(persona(1));
    const ex = collectException(d.runFrame());
    assert(ex.msg == "a" && ex.next !is null && ex.next.msg == "b");
}

/// A throwing call result handler is still removed after it runs.
unittest
{
    import std.exception : collectException;

    auto src = new FakeSource;
    auto d = CallbackDispatcher(1, src);
    auto t = d.callResult!LeaderboardFindResult_t(30, (ref r, io) { throw new Exception("x"); });
    src.complete(30, board(1));
    assert(collectException(d.runFrame()) !is null);
    assert(!d.isPending(t) && d.pendingCallResultCount == 0);
}

/// runFrame called from a handler does nothing.
unittest
{
    auto src = new FakeSource;
    auto d = CallbackDispatcher(1, src);
    int calls;
    d.register!PersonaStateChange_t((ref e) { ++calls; d.runFrame(); });
    src.push(persona(1));
    src.push(persona(2));
    d.runFrame();
    assert(calls == 2 && src.frames == 1 && src.drained);
}

/// Pipe 0 (before Steam starts) leaves the source alone.
unittest
{
    auto src = new FakeSource;
    CallbackDispatcher d;
    d.source = src;
    d.runFrame();
    assert(src.frames == 0);
    d.pipe = 3;
    d.runFrame();
    assert(src.frames == 1 && src.pipesSeen == [3]);
}

/// clear removes every handler and pending call result.
unittest
{
    auto src = new FakeSource;
    auto d = CallbackDispatcher(1, src);
    bool called;
    d.register!PersonaStateChange_t((ref e) { called = true; });
    d.callResult!LeaderboardFindResult_t(40, (ref r, io) { called = true; });
    d.clear();
    assert(d.handlerCount == 0 && d.pendingCallResultCount == 0);
    src.push(persona(1));
    src.complete(40, board(1));
    d.runFrame();
    assert(!called);
}

/// call!fn derives the result type from the function's attribute.
unittest
{
    static assert(is(CallResultOf!fakeFindLeaderboard == LeaderboardFindResult_t));
    static assert(is(CallResultOf!SteamAPI_ISteamUserStats_FindLeaderboard == LeaderboardFindResult_t));
    static assert(!__traits(compiles, CallResultOf!SteamAPI_RunCallbacks));

    auto src = new FakeSource;
    auto d = CallbackDispatcher(1, src);
    ulong handle;
    auto pending = d.call!fakeFindLeaderboard(50);
    assert(fakeFindCalls == 1 && pending.handle == 50);
    const t = pending.then((ref r, ioFailure) { handle = r.m_hSteamLeaderboard; });
    assert(t.call == 50);
    src.complete(50, board(7));
    d.runFrame();
    assert(handle == 7);
}

/// call!fn converts arguments as a direct call would, keeping ref and out
/// parameters.
unittest
{
    auto d = CallbackDispatcher(1, new FakeSource);
    auto written = new int;
    const extra = persona(1, 5);
    const pending = d.call!fakeFindByName("Feet", extra, *written);
    assert(pending.handle == 51 && *written == 5);
}

/// runFrame allocates nothing from the GC once handlers are registered.
unittest
{
    auto src = new FakeSource;
    auto d = CallbackDispatcher(1, src);
    ulong sum;
    d.register!PersonaStateChange_t((ref e) { sum += e.m_ulSteamID; });
    foreach (i; 0 .. 50)
    {
        src.push(persona(i));
        d.callResult!LeaderboardFindResult_t(100 + i, (ref r, io) { sum += r.m_hSteamLeaderboard; });
        src.complete(100 + i, board(i));
    }
    const before = GC.allocatedInCurrentThread;
    d.runFrame();
    assert(GC.allocatedInCurrentThread == before);
    assert(sum == 2 * (49 * 50 / 2));
}

version (unittest) private struct NogcGame
{
    ulong lastPersona;
    ulong board;
    bool failed;

    void onPersona(ref const PersonaStateChange_t e) nothrow @nogc
    {
        lastPersona = e.m_ulSteamID;
    }

    void onBoard(ref const LeaderboardFindResult_t r, bool ioFailure) nothrow @nogc
    {
        board = r.m_hSteamLeaderboard;
        failed = ioFailure;
    }

    void onRaw(ref const CallbackMsg_t) nothrow @nogc
    {
    }
}

/// NogcCallbackDispatcher works entirely within nothrow @nogc code.
unittest
{
    auto src = new FakeSource;
    src.push(persona(9));
    src.complete(60, board(61));
    NogcGame game;
    static void frame(ref NogcCallbackDispatcher d, ref NogcGame game) nothrow @nogc
    {
        d.register(&game.onPersona);
        d.registerRaw(&game.onRaw);
        d.callResult(60, &game.onBoard);
        d.runFrame();
    }

    auto d = NogcCallbackDispatcher(1, src);
    frame(d, game);
    assert(game.lastPersona == 9 && game.board == 61 && !game.failed);
}

/// NogcCallbackDispatcher rejects handlers that may throw or allocate.
unittest
{
    static assert(!__traits(compiles, {
            NogcCallbackDispatcher d;
            d.register((ref const PersonaStateChange_t e) { throw new Exception(""); });
        }));
    static assert(!__traits(compiles, {
            NogcCallbackDispatcher d;
            d.register((ref const PersonaStateChange_t e) { cast(void) new int; });
        }));
    static assert(__traits(compiles, {
            NogcCallbackDispatcher d;
            d.register((ref const PersonaStateChange_t e) nothrow @nogc {});
        }));
}

/// Moving a dispatcher keeps its registrations.
unittest
{
    import core.lifetime : move;

    auto src = new FakeSource;
    auto a = CallbackDispatcher(1, src);
    int calls;
    a.register!PersonaStateChange_t((ref e) { ++calls; });
    auto b = move(a);
    src.push(persona(1));
    b.runFrame();
    assert(calls == 1 && b.handlerCount == 1);
}

/// The default source is Steam's manual dispatch.
unittest
{
    assert(cast(ManualDispatchSource) manualDispatchSource() !is null);
    static assert(!__traits(compiles, { CallbackDispatcher a; auto b = a; }));
}
