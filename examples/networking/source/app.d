/// Messages over `ISteamNetworkingSockets` connections.
///
///   networking                  connects two sockets inside this process
///                               (CreateSocketPair), sends a batch of messages
///                               (SendMessages) and replies one by one; needs
///                               no second machine
///   networking --listen         accepts peer-to-peer connections through the
///                               Steam relay network and echoes every message
///   networking --connect ID     connects to a listening peer by Steam ID
///                               ("[U:1:22202]", "STEAM_1:0:11101" or the
///                               64-bit number) and sends a message a second
///
/// Connection state changes arrive as `SteamNetConnectionStatusChangedCallback_t`
/// callbacks through the dispatcher; messages are polled each frame with
/// `ReceiveMessagesOnConnection` / `ReceiveMessagesOnPollGroup` and released
/// with `SteamNetworkingMessage_t::Release`.
///
/// Run it with Steam running and a steam_appid.txt containing an app ID
/// (480, Spacewar, works for testing) in the working directory. --listen and
/// --connect need two Steam accounts, on one machine or two.
module app;

import core.thread : Thread;
import core.time : msecs, MonoTime, seconds;
import std.format : format;
import std.getopt : defaultGetoptPrinter, getopt;
import std.stdio : stderr, writefln, writeln;

import steamworks;

int main(string[] args)
{
    bool listen;
    string connect;
    int duration = 30;
    auto help = getopt(args, "listen", "Accept peer-to-peer connections and echo messages", &listen, "connect",
            "Connect to this listening Steam ID", &connect, "seconds", "How long to run (default 30)", &duration);
    if (help.helpWanted)
    {
        defaultGetoptPrinter("Usage: networking [--listen | --connect STEAMID] [--seconds N]", help.options);
        return 0;
    }
    CSteamID peer;
    if (connect.length && !parseSteamID(connect, peer))
    {
        stderr.writefln("not a Steam ID: %s", connect);
        return 2;
    }

    if (loadSteamworks() != SteamworksLoadStatus.success)
    {
        stderr.writefln("cannot load %s: %s", steamworksLibraryName, steamworksLoadError());
        return 1;
    }
    const init = steamInit();
    if (!init)
    {
        writefln("Steam is not available: %s (%s)", init.message, init.result);
        return 0;
    }
    scope (exit)
        steamShutdown();

    auto steam = CallbackDispatcher.forClient();
    if (listen)
        runListener(steam, duration);
    else if (connect.length)
        runClient(steam, peer, duration);
    else
        runLoopback(steam);
    return 0;
}

/// Sends messages between the two ends of a socket pair.
void runLoopback(ref CallbackDispatcher steam)
{
    auto sockets = SteamNetworkingSockets();
    HSteamNetConnection a, b;
    if (!SteamAPI_ISteamNetworkingSockets_CreateSocketPair(sockets, &a, &b, false, null, null))
        return writeln("cannot create a socket pair");
    scope (exit)
    {
        SteamAPI_ISteamNetworkingSockets_CloseConnection(sockets, a,
                k_ESteamNetConnectionEnd_App_Generic, "done", false);
        SteamAPI_ISteamNetworkingSockets_CloseConnection(sockets, b,
                k_ESteamNetConnectionEnd_App_Generic, "done", false);
    }

    string[5] pings;
    foreach (i, ref ping; pings)
        ping = format("ping %s", i);
    sendBatch(sockets, a, pings[]);
    int received;
    foreach (_; 0 .. 100)
    {
        steam.runFrame();
        receive(sockets, b, (const(char)[] text) {
            writefln("b received %s", text);
            send(sockets, b, "pong" ~ text[4 .. $]);
        });
        receive(sockets, a, (const(char)[] text) { writefln("a received %s", text); ++received; });
        if (received == 5)
            break;
        Thread.sleep(10.msecs);
    }
    writefln("%s of 5 round trips completed", received);
}

/// Accepts connections on virtual port 0 and echoes what each peer sends.
void runListener(ref CallbackDispatcher steam, int duration)
{
    auto sockets = SteamNetworkingSockets();
    // Fetches the relay network configuration now rather than on the first
    // connection, so that peers connect sooner.
    SteamAPI_ISteamNetworkingUtils_InitRelayNetworkAccess(SteamNetworkingUtils());

    const listenSocket = SteamAPI_ISteamNetworkingSockets_CreateListenSocketP2P(sockets, 0, 0, null);
    const group = SteamAPI_ISteamNetworkingSockets_CreatePollGroup(sockets);
    scope (exit)
    {
        SteamAPI_ISteamNetworkingSockets_CloseListenSocket(sockets, listenSocket);
        SteamAPI_ISteamNetworkingSockets_DestroyPollGroup(sockets, group);
    }
    writefln("listening as %s", CSteamID(SteamAPI_ISteamUser_GetSteamID(SteamUser())).toSteam3String);

    steam.register((ref const SteamNetConnectionStatusChangedCallback_t e) {
        const who = e.m_info.m_identityRemote.GetSteamID().toSteam3String;
        switch (e.m_info.m_eState)
        {
        case k_ESteamNetworkingConnectionState_Connecting:
            // A peer is knocking on our listen socket.
            if (e.m_info.m_hListenSocket == listenSocket
                && SteamAPI_ISteamNetworkingSockets_AcceptConnection(sockets, e.m_hConn) == k_EResultOK)
                SteamAPI_ISteamNetworkingSockets_SetConnectionPollGroup(sockets, e.m_hConn, group);
            break;
        case k_ESteamNetworkingConnectionState_Connected:
            writefln("%s connected", who);
            break;
        case k_ESteamNetworkingConnectionState_ClosedByPeer:
        case k_ESteamNetworkingConnectionState_ProblemDetectedLocally:
            writefln("%s disconnected: %s", who, fromCString(e.m_info.m_szEndDebug));
            // Closing frees the handle, also for connections the peer closed.
            SteamAPI_ISteamNetworkingSockets_CloseConnection(sockets, e.m_hConn, 0, null, false);
            break;
        default:
            break;
        }
    });

    const deadline = MonoTime.currTime + duration.seconds;
    while (MonoTime.currTime < deadline)
    {
        steam.runFrame();
        SteamNetworkingMessage_t*[32] messages;
        const n = SteamAPI_ISteamNetworkingSockets_ReceiveMessagesOnPollGroup(sockets, group,
                messages.ptr, cast(int) messages.length);
        foreach (m; messages[0 .. n])
        {
            const text = (cast(const(char)*) m.m_pData)[0 .. m.m_cbSize];
            writefln("%s: %s", m.m_identityPeer.GetSteamID().toSteam3String, text);
            send(sockets, m.m_conn, text);
            SteamAPI_SteamNetworkingMessage_t_Release(m);
        }
        Thread.sleep(10.msecs);
    }
}

/// Connects to `peer` and sends a message every second, printing the echoes.
void runClient(ref CallbackDispatcher steam, CSteamID peer, int duration)
{
    auto sockets = SteamNetworkingSockets();
    SteamAPI_ISteamNetworkingUtils_InitRelayNetworkAccess(SteamNetworkingUtils());

    SteamNetworkingIdentity identity;
    identity.SetSteamID(peer);
    const conn = SteamAPI_ISteamNetworkingSockets_ConnectP2P(sockets, identity, 0, 0, null);
    scope (exit)
        SteamAPI_ISteamNetworkingSockets_CloseConnection(sockets, conn,
                k_ESteamNetConnectionEnd_App_Generic, "bye", true);

    bool connected, closed;
    steam.register((ref const SteamNetConnectionStatusChangedCallback_t e) {
        if (e.m_hConn != conn)
            return;
        if (e.m_info.m_eState == k_ESteamNetworkingConnectionState_Connected)
        {
            connected = true;
            writefln("connected to %s", peer.toSteam3String);
        }
        else if (e.m_info.m_eState == k_ESteamNetworkingConnectionState_ClosedByPeer
            || e.m_info.m_eState == k_ESteamNetworkingConnectionState_ProblemDetectedLocally)
        {
            closed = true;
            writefln("connection closed: %s", fromCString(e.m_info.m_szEndDebug));
        }
    });

    const deadline = MonoTime.currTime + duration.seconds;
    auto nextSend = MonoTime.currTime;
    int sequence;
    while (!closed && MonoTime.currTime < deadline)
    {
        steam.runFrame();
        if (connected && MonoTime.currTime >= nextSend)
        {
            send(sockets, conn, format("message %s", sequence++));
            nextSend += 1.seconds;
        }
        receive(sockets, conn, (const(char)[] text) { writefln("echo: %s", text); });
        Thread.sleep(10.msecs);
    }
}

/// Sends `text` reliably on `conn`.
void send(ISteamNetworkingSockets* sockets, HSteamNetConnection conn, const(char)[] text)
{
    const r = SteamAPI_ISteamNetworkingSockets_SendMessageToConnection(sockets, conn, text.ptr,
            cast(uint) text.length, k_nSteamNetworkingSend_Reliable, null);
    if (r != k_EResultOK)
        writefln("send failed: %s", r);
}

/// Sends `texts` reliably on `conn` as one batch with `SendMessages`. With
/// bDeleteFailedMessages true the library takes ownership of every message,
/// including those it fails to queue, so none needs releasing here.
void sendBatch(ISteamNetworkingSockets* sockets, HSteamNetConnection conn, const(char[])[] texts)
{
    auto messages = new SteamNetworkingMessage_t*[texts.length];
    foreach (i, text; texts)
    {
        auto m = SteamAPI_ISteamNetworkingUtils_AllocateMessage(SteamNetworkingUtils(), cast(int) text.length);
        (cast(char*) m.m_pData)[0 .. text.length] = text[];
        m.m_conn = conn;
        m.m_nFlags = k_nSteamNetworkingSend_Reliable;
        messages[i] = m;
    }
    auto results = new long[texts.length];
    SteamAPI_ISteamNetworkingSockets_SendMessages(sockets, cast(int) messages.length, messages.ptr, results.ptr, true);
    // Each result is the message number, a negative EResult, or 0 for a
    // message not attempted after an earlier one on the connection failed.
    foreach (i, r; results)
        if (r <= 0)
            writefln("message %s not sent: %s", i, r == 0 ? "not attempted" : format("%s", cast(EResult)-r));
}

/// Passes every message waiting on `conn` to `handler`, then releases it.
void receive(ISteamNetworkingSockets* sockets, HSteamNetConnection conn, scope void delegate(const(char)[]) handler)
{
    SteamNetworkingMessage_t*[16] messages;
    const n = SteamAPI_ISteamNetworkingSockets_ReceiveMessagesOnConnection(sockets, conn,
            messages.ptr, cast(int) messages.length);
    foreach (m; messages[0 .. n])
    {
        scope (exit)
            SteamAPI_SteamNetworkingMessage_t_Release(m);
        handler((cast(const(char)*) m.m_pData)[0 .. m.m_cbSize]);
    }
}
