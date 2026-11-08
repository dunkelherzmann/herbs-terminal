// pack.exe <folder> <version> <payload.bin>
//
// Build tool for dev\build.ps1 -Package: packs every file under <folder> into the payload that launcher.c
// carries (format in payload.h). The cache id is the version plus a hash of the packed files, so a rebuild with
// different contents never reuses an older unpacked copy.
#define WIN32_LEAN_AND_MEAN
#define UNICODE
#include <windows.h>
#include <compressapi.h>
#include <stdio.h>
#include <stdlib.h>
#include <wchar.h>
#include "payload.h"

static unsigned char *list;
static size_t listSize, listCapacity;

static void fail(const wchar_t *what) {
    fwprintf(stderr, L"pack: %ls (error %lu)\n", what, GetLastError());
    exit(1);
}

static void reserve(size_t size) {
    if (listSize + size <= listCapacity) return;
    listCapacity = (listSize + size) * 2;
    list = realloc(list, listCapacity);
    if (!list) fail(L"out of memory");
}

static void append(const void *data, size_t size) {
    reserve(size);
    memcpy(list + listSize, data, size);
    listSize += size;
}

// Adds every file in root\relative (relative may be empty), folders depth first.
static void addFolder(const wchar_t *root, const wchar_t *relative) {
    wchar_t pattern[MAX_PATH * 2];
    swprintf(pattern, MAX_PATH * 2, *relative ? L"%ls\\%ls\\*" : L"%ls%ls\\*", root, relative);
    WIN32_FIND_DATAW found;
    HANDLE search = FindFirstFileW(pattern, &found);
    if (search == INVALID_HANDLE_VALUE) fail(pattern);
    do {
        if (!wcscmp(found.cFileName, L".") || !wcscmp(found.cFileName, L"..")) continue;
        wchar_t name[MAX_PATH * 2];
        swprintf(name, MAX_PATH * 2, *relative ? L"%ls\\%ls" : L"%ls%ls", relative, found.cFileName);
        if (found.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) { addFolder(root, name); continue; }

        wchar_t path[MAX_PATH * 3];
        swprintf(path, MAX_PATH * 3, L"%ls\\%ls", root, name);
        HANDLE file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, NULL, OPEN_EXISTING, 0, NULL);
        if (file == INVALID_HANDLE_VALUE) fail(path);
        LARGE_INTEGER size;
        if (!GetFileSizeEx(file, &size)) fail(path);
        PayloadEntry entry = { (uint32_t)wcslen(name), (uint64_t)size.QuadPart };
        append(&entry, sizeof entry);
        append(name, entry.nameLength * sizeof(wchar_t));
        reserve((size_t)entry.dataLength);
        size_t start = listSize;
        DWORD read;
        uint64_t done = 0;
        while (done < entry.dataLength) {
            DWORD chunk = (DWORD)min(entry.dataLength - done, 1u << 30);
            if (!ReadFile(file, list + start + done, chunk, &read, NULL) || read == 0) fail(path);
            done += read;
        }
        listSize += entry.dataLength;
        CloseHandle(file);
    } while (FindNextFileW(search, &found));
    FindClose(search);
}

int wmain(int argc, wchar_t **argv) {
    if (argc != 4) {
        fwprintf(stderr, L"usage: pack <folder> <version> <payload.bin>\n");
        return 2;
    }
    addFolder(argv[1], L"");

    // FNV-1a over the file list: enough to tell builds apart, not a security check.
    uint64_t hash = 14695981039346656037ull;
    for (size_t i = 0; i < listSize; i++) hash = (hash ^ list[i]) * 1099511628211ull;

    PayloadHeader header = { 0 };
    memcpy(header.magic, PAYLOAD_MAGIC, 8);
    header.unpackedSize = listSize;
    swprintf(header.id, 64, L"%ls-%012llx", argv[2], hash & 0xffffffffffffull);

    COMPRESSOR_HANDLE compressor;
    if (!CreateCompressor(COMPRESS_ALGORITHM_LZMS, NULL, &compressor)) fail(L"CreateCompressor");
    SIZE_T packedSize = 0;
    Compress(compressor, list, listSize, NULL, 0, &packedSize);
    unsigned char *packed = malloc(packedSize);
    if (!packed || !Compress(compressor, list, listSize, packed, packedSize, &packedSize)) fail(L"Compress");
    CloseCompressor(compressor);

    HANDLE out = CreateFileW(argv[3], GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, 0, NULL);
    DWORD written;
    if (out == INVALID_HANDLE_VALUE || !WriteFile(out, &header, sizeof header, &written, NULL) ||
        !WriteFile(out, packed, (DWORD)packedSize, &written, NULL) || written != packedSize) fail(argv[3]);
    CloseHandle(out);
    wprintf(L"%ls\n", header.id);
    return 0;
}
