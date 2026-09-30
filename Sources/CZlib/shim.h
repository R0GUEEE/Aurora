#ifndef AURORA_CZLIB_SHIM_H
#define AURORA_CZLIB_SHIM_H

// zlib ships with the iOS and macOS SDKs (/usr/lib/libz.1.dylib) and is the
// only decompressor guaranteed to be present on a jailbroken device, so the
// gzip family goes through it instead of a vendored C dependency.
#include <zlib.h>

#endif /* AURORA_CZLIB_SHIM_H */
