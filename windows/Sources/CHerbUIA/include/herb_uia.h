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
    int toggle;                          // a toggle button: 1 on, 0 off; -1 for other items
    int selected;                        // a tab: 1 selected, 0 not; -1 for other items
} HerbUIAItem;

/// Replaces the items `hwnd` shows to UI Automation (copied; the caller keeps its own strings).
void herb_uia_set_items(void *hwnd, const HerbUIAItem *items, int count);

/// Answers WM_GETOBJECT for the window. Returns 1 and sets `*result` when it handled the message.
int herb_uia_get_object(void *hwnd, uintptr_t wParam, intptr_t lParam, intptr_t *result);

/// Call from WM_DESTROY: disconnects the window's providers and frees its items.
void herb_uia_window_destroyed(void *hwnd);

/// Feature tests: moves a top-level window of this process to the virtual desktop named `name` (made once by the
/// test setup). Returns 0 when there is no such desktop or the move failed, so the window stays where it is.
int herb_move_to_named_desktop(void *hwnd, const uint16_t *name);

/// The name screen readers read for a standard control whose text is an icon (Dynamic Annotation). Returns 0
/// when it couldn't be set.
int herb_set_accessible_name(void *hwnd, const uint16_t *name);

// MARK: The terminal's text (herb_text.c)

/// Registers the app's function that answers herb_uia_text_set for a terminal window whose text is stale. It runs
/// only when an assistive tool reads the terminal.
void herb_uia_text_register(void (*refresh)(void *hwnd));

/// Whether any assistive tool is listening (UiaClientsAreListening), so the app can skip work nobody reads.
int herb_uia_listening(void);

/// The terminal's visible text, one line per row joined with "\n"; `caret` is the cursor's offset in it, and the
/// cell grid (client pixels) places each character on screen.
void herb_uia_text_set(void *hwnd, const unsigned short *name, const unsigned short *text, int length, int caret,
                       int left, int top, int cellWidth, int cellHeight);

/// Marks the text stale and tells listening tools it changed (`textChanged` 1) or only the cursor moved (0).
void herb_uia_text_changed(void *hwnd, int textChanged);

/// Has screen readers read `text` (a UI Automation notification), for new output in the terminal.
void herb_uia_text_announce(void *hwnd, const unsigned short *text);

/// Answers WM_GETOBJECT for a terminal window. Returns 1 and sets `*result` when it handled the message.
int herb_uia_text_get_object(void *hwnd, uintptr_t wParam, intptr_t lParam, intptr_t *result);

/// Call from the terminal window's WM_DESTROY.
void herb_uia_text_destroyed(void *hwnd);

#endif
