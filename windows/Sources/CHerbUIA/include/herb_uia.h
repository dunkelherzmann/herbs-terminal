#ifndef HERB_UIA_H
#define HERB_UIA_H

#include <stdint.h>

// UI Automation for parts of a window that are drawn rather than child controls (the toolbar, the tab strip and
// the window buttons). Screen readers, Windows' accessibility tools and the parity check see each one as a control
// with an identifier, a name, hover text, a shortcut and a place on screen.

/// Posted to the window when an assistive tool presses an item: wParam is the item's tag. (WM_APP + 0x55)
enum { HERB_UIA_INVOKE_MESSAGE = 0x8000 + 0x55 };

/// The UIA control types used here (UIA_ButtonControlTypeId, UIA_TabItemControlTypeId, UIA_TextControlTypeId).
enum { HERB_UIA_BUTTON = 50000, HERB_UIA_TAB_ITEM = 50019, HERB_UIA_TEXT = 50020 };

typedef struct HerbUIAItem {
    const unsigned short *automationId;  // the same string on every platform (toolbar.newTab, …)
    const unsigned short *name;
    const unsigned short *help;          // hover text; may be NULL
    const unsigned short *accelerator;   // keyboard shortcut; may be NULL
    int32_t left, top, right, bottom;    // in client pixels
    int controlType;                     // a HERB_UIA_… control type
    int enabled;
    int hasPopup;                        // opens a menu: offers Expand
    int invokable;                       // can be pressed: offers Invoke
    int tag;                             // the caller's own key, stable while the item exists
} HerbUIAItem;

/// Replaces the items `hwnd` shows to UI Automation (copied; the caller keeps its own strings).
void herb_uia_set_items(void *hwnd, const HerbUIAItem *items, int count);

/// Answers WM_GETOBJECT for the window. Returns 1 and sets `*result` when it handled the message.
int herb_uia_get_object(void *hwnd, uintptr_t wParam, intptr_t lParam, intptr_t *result);

/// Call from WM_DESTROY: disconnects the window's providers and frees its items.
void herb_uia_window_destroyed(void *hwnd);

#endif
