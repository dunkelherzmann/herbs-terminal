// The macOS sources import Darwin for the C library; on Linux that is Glibc. `Darwin.read` and the like resolve
// through this re-export.
@_exported import Glibc
