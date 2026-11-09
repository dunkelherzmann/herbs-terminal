// Input methods (Chinese, Japanese, Korean…) in the terminal: the composition and candidate windows sit at the
// terminal's cursor, in the terminal's font. See include/herb_uia.h.

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <imm.h>

#include "herb_uia.h"

int herb_ime_place(void *window, int x, int y, int lineHeight, const uint16_t *face, int fontHeight) {
    HWND hwnd = (HWND)window;
    HIMC context = ImmGetContext(hwnd);
    if (!context) return 0;
    COMPOSITIONFORM composition = {0};
    composition.dwStyle = CFS_POINT;
    composition.ptCurrentPos.x = x;
    composition.ptCurrentPos.y = y;
    ImmSetCompositionWindow(context, &composition);
    // The candidate list opens below the cursor's line, never over it.
    CANDIDATEFORM candidate = {0};
    candidate.dwIndex = 0;
    candidate.dwStyle = CFS_EXCLUDE;
    candidate.ptCurrentPos.x = x;
    candidate.ptCurrentPos.y = y;
    candidate.rcArea.left = x;
    candidate.rcArea.top = y;
    candidate.rcArea.right = x + 1;
    candidate.rcArea.bottom = y + lineHeight;
    ImmSetCandidateWindow(context, &candidate);
    if (face) {
        LOGFONTW font = {0};
        font.lfHeight = -fontHeight;
        font.lfCharSet = DEFAULT_CHARSET;
        lstrcpynW(font.lfFaceName, (const wchar_t *)face, LF_FACESIZE);
        ImmSetCompositionFontW(context, &font);
    }
    ImmReleaseContext(hwnd, context);
    return 1;
}

int herb_ime_position(void *window, int *x, int *y) {
    HWND hwnd = (HWND)window;
    HIMC context = ImmGetContext(hwnd);
    if (!context) return 0;
    COMPOSITIONFORM composition = {0};
    int ok = ImmGetCompositionWindow(context, &composition) ? 1 : 0;
    *x = composition.ptCurrentPos.x;
    *y = composition.ptCurrentPos.y;
    ImmReleaseContext(hwnd, context);
    return ok;
}
