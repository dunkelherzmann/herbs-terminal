// The macOS sources import Darwin for the C library and BSD sockets; on Windows those are the Universal CRT and
// Winsock (inet_pton, in_addr…). `Darwin.read` and the like resolve through these re-exports.
@_exported import ucrt
@_exported import WinSDK
