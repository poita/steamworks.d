/// D bindings for the Steamworks SDK flat C API.
///
/// `steamworks.raw` is the complete flat API with Valve's C names: every
/// interface handle, exported function, struct, callback, enum, constant and
/// typedef, so the Steamworks documentation applies as written.
/// `steamworks.loader` loads the library at runtime when the "dynamic" dub
/// configuration is used.
///
/// A thin D layer sits on top, leaving the raw API fully usable:
/// `steamworks.lifecycle` (initialization and shutdown),
/// `steamworks.accessors` (`SteamUser()` and the other interface accessors),
/// `steamworks.dispatch` (callbacks and call results through manual dispatch),
/// `steamworks.matchmaking` (delegate-based server browser responses),
/// `steamworks.steamid`, `steamworks.networking` and `steamworks.strings`
/// (conversions).
module steamworks;

public import steamworks.accessors;
public import steamworks.dispatch;
public import steamworks.lifecycle;
public import steamworks.loader;
public import steamworks.matchmaking;
public import steamworks.networking;
public import steamworks.raw;
public import steamworks.steamid;
public import steamworks.strings;
