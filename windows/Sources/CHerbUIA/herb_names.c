// Accessible names for standard controls that show an icon instead of words; see include/herb_uia.h.

#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <objbase.h>
#include <oleacc.h>
#include <stdint.h>

#include "herb_uia.h"

// Spelled out, so no extra import library is needed.
static const CLSID clsidServices = {0xb5f8350b, 0x0548, 0x48b1, {0xa6, 0xee, 0x88, 0xbd, 0x00, 0xb4, 0xa5, 0xe7}};
static const IID iidServices = {0x6e26e776, 0x04f0, 0x495d, {0x80, 0xe4, 0x33, 0x30, 0x35, 0x2e, 0x31, 0x69}};
static const GUID propertyName = {0x608d3df8, 0x8128, 0x4aa7, {0xa4, 0x28, 0xf5, 0x5e, 0x49, 0x26, 0x72, 0x91}};

int herb_set_accessible_name(void *hwnd, const uint16_t *name) {
    CoInitializeEx(NULL, COINIT_APARTMENTTHREADED);
    IAccPropServices *services = NULL;
    if (FAILED(CoCreateInstance(&clsidServices, NULL, CLSCTX_INPROC_SERVER, &iidServices, (void **)&services))) return 0;
    HRESULT result = IAccPropServices_SetHwndPropStr(services, (HWND)hwnd, (DWORD)OBJID_CLIENT, CHILDID_SELF, propertyName,
                                                     (LPCWSTR)name);
    IAccPropServices_Release(services);
    return SUCCEEDED(result) ? 1 : 0;
}
