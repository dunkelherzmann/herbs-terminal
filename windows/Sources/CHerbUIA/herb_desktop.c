// The feature tests' own virtual desktop; see include/herb_uia.h.

#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <objbase.h>
#include <shobjidl.h>
#include <wchar.h>

#include "herb_uia.h"

// Spelled out, so no extra import library is needed.
static const CLSID clsidManager = {0xAA509086, 0x5CA9, 0x4C25, {0x8F, 0x95, 0x58, 0x9D, 0x3C, 0x07, 0xB4, 0x8A}};
static const IID iidManager = {0xA5CD92FF, 0x29BE, 0x454C, {0x8D, 0x04, 0xD8, 0x28, 0x79, 0xFB, 0x3F, 0x1B}};

// The id of the virtual desktop named `name`, from Explorer's own record of its desktops.
static BOOL findDesktop(const wchar_t *name, GUID *found) {
    HKEY desktops;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, L"Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\VirtualDesktops\\Desktops",
                      0, KEY_READ, &desktops) != ERROR_SUCCESS) return FALSE;
    BOOL result = FALSE;
    wchar_t key[64];
    for (DWORD index = 0;; index++) {
        DWORD length = 64;
        if (RegEnumKeyExW(desktops, index, key, &length, NULL, NULL, NULL, NULL) != ERROR_SUCCESS) break;
        wchar_t value[256];
        DWORD size = sizeof(value);
        if (RegGetValueW(desktops, key, L"Name", RRF_RT_REG_SZ, NULL, value, &size) != ERROR_SUCCESS) continue;
        if (wcscmp(value, name) == 0 && SUCCEEDED(CLSIDFromString(key, found))) { result = TRUE; break; }
    }
    RegCloseKey(desktops);
    return result;
}

int herb_move_to_named_desktop(void *hwnd, const uint16_t *wideName) {
    HWND window = (HWND)hwnd;
    const wchar_t *name = (const wchar_t *)wideName;
    static GUID desktop;
    static int state = 0;  // 0 not looked up, 1 found, -1 missing
    if (state == 0) state = findDesktop(name, &desktop) ? 1 : -1;
    if (state < 0) return 0;
    CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
    IVirtualDesktopManager *manager = NULL;
    if (FAILED(CoCreateInstance(&clsidManager, NULL, CLSCTX_ALL, &iidManager, (void **)&manager))) return 0;
    GUID current;
    HRESULT result = S_OK;
    if (FAILED(IVirtualDesktopManager_GetWindowDesktopId(manager, window, &current)) || !IsEqualGUID(&current, &desktop))
        result = IVirtualDesktopManager_MoveWindowToDesktop(manager, window, &desktop);
    IVirtualDesktopManager_Release(manager);
    return SUCCEEDED(result) ? 1 : 0;
}
