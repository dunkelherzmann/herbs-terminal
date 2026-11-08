// The packed app inside the single HerbsTerminal.exe (dev\build.ps1 -Package).
//
// The launcher carries it as resource RCDATA 1:
//   PayloadHeader, then the file list compressed with Windows' LZMS (cabinet.dll's Compression API).
// The file list, once decompressed, is a run of entries:
//   uint32 name length in UTF-16 units, uint64 data length, the relative path (UTF-16, '\' separators), the data.
#pragma once
#include <stdint.h>

#define PAYLOAD_MAGIC "HTPAYLD1"
#define PAYLOAD_RESOURCE 1

#pragma pack(push, 1)
typedef struct {
    char magic[8];                 // PAYLOAD_MAGIC
    uint64_t unpackedSize;         // size of the file list after decompression
    wchar_t id[64];                // "<version>-<content hash>", the cache folder's name (NUL-terminated)
} PayloadHeader;

typedef struct {
    uint32_t nameLength;
    uint64_t dataLength;
} PayloadEntry;
#pragma pack(pop)
