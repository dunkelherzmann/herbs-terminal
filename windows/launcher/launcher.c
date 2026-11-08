// The single portable HerbsTerminal.exe.
//
// The Swift toolchain for Windows can't produce one self-contained exe yet: its static runtime libraries are
// built against the DLL version of the Microsoft C++ runtime, so the app always needs vcruntime140, msvcp140 and
// the Swift DLLs beside it. This small launcher (plain C, static C runtime, Windows DLLs only) carries that
// folder inside itself (payload.h), unpacks it once per build to
// %LOCALAPPDATA%\HerbsTerminal\Versions\<version>-<hash>, removes the copies of older builds, and runs the app
// there with the same command line, waiting for it and passing on its exit code. Nothing is installed or
// registered; deleting the exe and that folder removes every trace.
#define WIN32_LEAN_AND_MEAN
#define UNICODE
#include <windows.h>
#include <compressapi.h>
#include <shlobj.h>
#include <wchar.h>
#include "payload.h"

#define PATH_CAPACITY 1024

static void report(const wchar_t *what, DWORD error) {
    wchar_t message[PATH_CAPACITY + 256], reason[256] = L"";
    FormatMessageW(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS, NULL, error, 0, reason, 256, NULL);
    swprintf(message, PATH_CAPACITY + 256, L"Herb's Terminal couldn't start: %ls\n\n%ls", what, reason);
    MessageBoxW(NULL, message, L"Herb's Terminal", MB_ICONERROR | MB_OK);
}

static BOOL exists(const wchar_t *path) { return GetFileAttributesW(path) != INVALID_FILE_ATTRIBUTES; }

// Deletes a folder and everything in it, as far as possible (files in use stay). Links are removed, not followed.
static void removeTree(const wchar_t *folder) {
    wchar_t pattern[PATH_CAPACITY];
    swprintf(pattern, PATH_CAPACITY, L"%ls\\*", folder);
    WIN32_FIND_DATAW found;
    HANDLE search = FindFirstFileW(pattern, &found);
    if (search != INVALID_HANDLE_VALUE) {
        do {
            if (!wcscmp(found.cFileName, L".") || !wcscmp(found.cFileName, L"..")) continue;
            wchar_t path[PATH_CAPACITY];
            swprintf(path, PATH_CAPACITY, L"%ls\\%ls", folder, found.cFileName);
            if ((found.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) && !(found.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT)) {
                removeTree(path);
            } else if (found.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
                RemoveDirectoryW(path);
            } else {
                SetFileAttributesW(path, FILE_ATTRIBUTE_NORMAL);
                DeleteFileW(path);
            }
        } while (FindNextFileW(search, &found));
        FindClose(search);
    }
    RemoveDirectoryW(folder);
}

// A name from the payload must stay inside the folder it's unpacked to.
static BOOL safeName(const wchar_t *name) {
    if (!*name || name[0] == L'\\' || name[0] == L'/' || wcschr(name, L':')) return FALSE;
    for (const wchar_t *part = name; *part;) {
        const wchar_t *end = part + wcscspn(part, L"\\/");
        if (end - part == 2 && part[0] == L'.' && part[1] == L'.') return FALSE;
        part = *end ? end + 1 : end;
    }
    return TRUE;
}

// Unpacks the file list into folder. Returns 0 or a Windows error code.
static DWORD unpack(const unsigned char *packed, SIZE_T packedSize, uint64_t unpackedSize, const wchar_t *folder) {
    DECOMPRESSOR_HANDLE decompressor;
    if (!CreateDecompressor(COMPRESS_ALGORITHM_LZMS, NULL, &decompressor)) return GetLastError();
    unsigned char *list = VirtualAlloc(NULL, (SIZE_T)unpackedSize, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    SIZE_T size = 0;
    DWORD error = 0;
    if (!list) error = GetLastError();
    else if (!Decompress(decompressor, packed, packedSize, list, (SIZE_T)unpackedSize, &size)) error = GetLastError();
    else if (size != unpackedSize) error = ERROR_INVALID_DATA;
    CloseDecompressor(decompressor);

    for (SIZE_T at = 0; !error && at < size;) {
        PayloadEntry entry;
        if (size - at < sizeof entry) { error = ERROR_INVALID_DATA; break; }
        memcpy(&entry, list + at, sizeof entry);
        at += sizeof entry;
        if (entry.nameLength == 0 || entry.nameLength >= 260 || (size - at) / sizeof(wchar_t) < entry.nameLength) { error = ERROR_INVALID_DATA; break; }
        wchar_t name[260];
        memcpy(name, list + at, entry.nameLength * sizeof(wchar_t));
        name[entry.nameLength] = 0;
        at += entry.nameLength * sizeof(wchar_t);
        if (!safeName(name) || size - at < entry.dataLength) { error = ERROR_INVALID_DATA; break; }

        wchar_t path[PATH_CAPACITY];
        swprintf(path, PATH_CAPACITY, L"%ls\\%ls", folder, name);
        for (wchar_t *slash = path + wcslen(folder) + 1; (slash = wcschr(slash, L'\\')); slash++) {
            *slash = 0;
            CreateDirectoryW(path, NULL);
            *slash = L'\\';
        }
        HANDLE file = CreateFileW(path, GENERIC_WRITE, 0, NULL, CREATE_NEW, FILE_ATTRIBUTE_NORMAL, NULL);
        if (file == INVALID_HANDLE_VALUE) { error = GetLastError(); break; }
        for (uint64_t done = 0; done < entry.dataLength;) {
            DWORD chunk = (DWORD)min(entry.dataLength - done, 1u << 30), written;
            if (!WriteFile(file, list + at + done, chunk, &written, NULL)) { error = GetLastError(); break; }
            done += written;
        }
        CloseHandle(file);
        at += (SIZE_T)entry.dataLength;
    }
    if (list) VirtualFree(list, 0, MEM_RELEASE);
    return error;
}

// Removes the unpacked copies of other builds, and unfinished unpacking older than an hour. Copies in use keep
// the files Windows won't let go of; the next new build tries again.
static void removeOlderCopies(const wchar_t *versions, const wchar_t *current) {
    wchar_t pattern[PATH_CAPACITY];
    swprintf(pattern, PATH_CAPACITY, L"%ls\\*", versions);
    WIN32_FIND_DATAW found;
    HANDLE search = FindFirstFileW(pattern, &found);
    if (search == INVALID_HANDLE_VALUE) return;
    FILETIME now;
    GetSystemTimeAsFileTime(&now);
    ULONGLONG hourAgo = (((ULONGLONG)now.dwHighDateTime << 32) | now.dwLowDateTime) - 36000000000ull;
    do {
        if (!(found.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) || found.cFileName[0] == L'.' || !wcscmp(found.cFileName, current)) continue;
        ULONGLONG written = ((ULONGLONG)found.ftLastWriteTime.dwHighDateTime << 32) | found.ftLastWriteTime.dwLowDateTime;
        if (wcsstr(found.cFileName, L".partial-") && written > hourAgo) continue;
        wchar_t path[PATH_CAPACITY];
        swprintf(path, PATH_CAPACITY, L"%ls\\%ls", versions, found.cFileName);
        removeTree(path);
    } while (FindNextFileW(search, &found));
    FindClose(search);
}

// The command line after the launcher's own name, as Windows splits argv[0].
static const wchar_t *argumentsAfterProgram(const wchar_t *line) {
    if (*line == L'"') {
        line++;
        while (*line && *line != L'"') line++;
        if (*line) line++;
    } else {
        while (*line && *line != L' ' && *line != L'\t') line++;
    }
    return line;
}

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE previous, PWSTR arguments, int show) {
    (void)previous; (void)arguments; (void)show;
    HRSRC resource = FindResourceW(instance, MAKEINTRESOURCEW(PAYLOAD_RESOURCE), RT_RCDATA);
    HGLOBAL loaded = resource ? LoadResource(instance, resource) : NULL;
    const unsigned char *payload = loaded ? LockResource(loaded) : NULL;
    DWORD payloadSize = resource ? SizeofResource(instance, resource) : 0;
    PayloadHeader header;
    if (!payload || payloadSize < sizeof header) { report(L"the app inside this file is missing.", ERROR_INVALID_DATA); return 1; }
    memcpy(&header, payload, sizeof header);
    header.id[63] = 0;
    if (memcmp(header.magic, PAYLOAD_MAGIC, 8) || !safeName(header.id) || wcschr(header.id, L'\\')) {
        report(L"the app inside this file is damaged.", ERROR_INVALID_DATA);
        return 1;
    }

    wchar_t base[PATH_CAPACITY], versions[PATH_CAPACITY], folder[PATH_CAPACITY], exe[PATH_CAPACITY];
    DWORD length = GetEnvironmentVariableW(L"LOCALAPPDATA", base, PATH_CAPACITY);
    if (length == 0 || length >= PATH_CAPACITY - 200) {
        length = GetTempPathW(PATH_CAPACITY, base);
        if (length == 0 || length >= PATH_CAPACITY - 200) { report(L"there's no folder to unpack it to.", GetLastError()); return 1; }
        if (base[length - 1] == L'\\') base[length - 1] = 0;
    }
    swprintf(versions, PATH_CAPACITY, L"%ls\\HerbsTerminal\\Versions", base);
    swprintf(folder, PATH_CAPACITY, L"%ls\\%ls", versions, header.id);
    swprintf(exe, PATH_CAPACITY, L"%ls\\HerbsTerminal.exe", folder);

    if (!exists(exe)) {
        int made = SHCreateDirectoryExW(NULL, versions, NULL);
        if (made != ERROR_SUCCESS && made != ERROR_ALREADY_EXISTS) { report(versions, (DWORD)made); return 1; }
        // Unpack beside the final folder and rename it into place, so a copy is either complete or absent.
        wchar_t partial[PATH_CAPACITY];
        swprintf(partial, PATH_CAPACITY, L"%ls.partial-%lu-%lu", folder, GetCurrentProcessId(), GetTickCount());
        if (!CreateDirectoryW(partial, NULL)) { report(partial, GetLastError()); return 1; }
        DWORD error = unpack(payload + sizeof header, payloadSize - sizeof header, header.unpackedSize, partial);
        if (error) { removeTree(partial); report(L"the app couldn't be unpacked.", error); return 1; }
        if (!MoveFileExW(partial, folder, 0)) {
            error = GetLastError();
            if (!exists(exe) && exists(folder)) {          // a broken copy: replace it
                removeTree(folder);
                if (MoveFileExW(partial, folder, 0)) error = 0;
            }
            if (exists(partial)) removeTree(partial);      // another launch got there first, or it failed
            if (!exists(exe)) { report(folder, error); return 1; }
        }
        removeOlderCopies(versions, header.id);
    }

    // Run the app with this launcher's arguments and standard handles, and wait for it.
    const wchar_t *rest = argumentsAfterProgram(GetCommandLineW());
    size_t lineCapacity = wcslen(exe) + wcslen(rest) + 4;
    wchar_t *line = HeapAlloc(GetProcessHeap(), 0, lineCapacity * sizeof(wchar_t));
    if (!line) { report(L"out of memory.", ERROR_OUTOFMEMORY); return 1; }
    swprintf(line, lineCapacity, L"\"%ls\"%ls", exe, rest);

    STARTUPINFOW startup = { sizeof startup };
    GetStartupInfoW(&startup);
    startup.lpReserved = NULL;
    startup.lpTitle = NULL;
    startup.lpDesktop = NULL;
    startup.cbReserved2 = 0;
    startup.lpReserved2 = NULL;
    startup.dwFlags |= STARTF_USESTDHANDLES;
    startup.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
    startup.hStdOutput = GetStdHandle(STD_OUTPUT_HANDLE);
    startup.hStdError = GetStdHandle(STD_ERROR_HANDLE);
    PROCESS_INFORMATION process;
    if (!CreateProcessW(exe, line, NULL, NULL, TRUE, 0, NULL, NULL, &startup, &process)) {
        report(exe, GetLastError());
        return 1;
    }
    CloseHandle(process.hThread);
    WaitForSingleObject(process.hProcess, INFINITE);
    DWORD code = 1;
    GetExitCodeProcess(process.hProcess, &code);
    return (int)code;
}
