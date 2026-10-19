/// D bindings for the Steamworks SDK flat C API.
///
/// `steamworks.raw` is the complete flat API with Valve's C names: every
/// interface handle, exported function, struct, callback, enum, constant and
/// typedef, so the Steamworks documentation applies as written.
/// `steamworks.loader` loads the library at runtime when the "dynamic" dub
/// configuration is used.
module steamworks;

public import steamworks.loader;
public import steamworks.raw;
