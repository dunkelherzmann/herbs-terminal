// UI Automation providers for drawn window parts; see include/herb_uia.h.
//
// Each window gets one fragment root, hosted by its HWND (so the window's own name, frame and child windows still
// come from Windows), with one fragment per drawn item. Fragments look their item up by tag on every call, so they
// follow layout changes and report "not available" once their item is gone.

#define COBJMACROS
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <ole2.h>
#include <oleauto.h>
#include <uiautomation.h>
#include <stddef.h>
#include <stdlib.h>
#include <wchar.h>

#include "herb_uia.h"

#define CONTAINER(pointer, type, field) ((type *)((char *)(pointer) - offsetof(type, field)))

typedef struct Item {
    wchar_t *automationId, *name, *help, *accelerator;
    RECT rect;
    int controlType, enabled, hasPopup, invokable, tag;
    int toggle, selected;  // -1 when the item has no such state
} Item;

typedef struct Root {
    IRawElementProviderSimple simple;
    IRawElementProviderFragment fragment;
    IRawElementProviderFragmentRoot fragmentRoot;
    LONG refs;
    HWND hwnd;           // NULL once the window is gone
    Item *items;
    int count;
    struct Root *next;
} Root;

typedef struct Element {
    IRawElementProviderSimple simple;
    IRawElementProviderFragment fragment;
    IInvokeProvider invoke;
    IExpandCollapseProvider expandCollapse;
    IToggleProvider toggle;
    ISelectionItemProvider selection;
    LONG refs;
    Root *root;
    int tag;
} Element;

static Root *roots;  // every window's root; touched only on the UI thread

// MARK: Helpers

static wchar_t *copy(const unsigned short *text) {
    return text ? _wcsdup((const wchar_t *)text) : NULL;
}

static void free_items(Item *items, int count) {
    for (int i = 0; i < count; i++) {
        free(items[i].automationId);
        free(items[i].name);
        free(items[i].help);
        free(items[i].accelerator);
    }
    free(items);
}

static int index_of(Root *root, int tag) {
    if (!root->hwnd) return -1;
    for (int i = 0; i < root->count; i++)
        if (root->items[i].tag == tag) return i;
    return -1;
}

static void set_string(VARIANT *value, const wchar_t *text) {
    if (!text) return;
    value->vt = VT_BSTR;
    value->bstrVal = SysAllocString(text);
}

static void root_add_ref(Root *root) { InterlockedIncrement(&root->refs); }
static void root_release(Root *root);

static Element *element_new(Root *root, int tag);

// MARK: Element: IRawElementProviderSimple

static HRESULT STDMETHODCALLTYPE element_query(Element *self, REFIID riid, void **out) {
    *out = NULL;
    if (IsEqualIID(riid, &IID_IUnknown) || IsEqualIID(riid, &IID_IRawElementProviderSimple)) *out = &self->simple;
    else if (IsEqualIID(riid, &IID_IRawElementProviderFragment)) *out = &self->fragment;
    else if (IsEqualIID(riid, &IID_IInvokeProvider)) *out = &self->invoke;
    else if (IsEqualIID(riid, &IID_IExpandCollapseProvider)) *out = &self->expandCollapse;
    else if (IsEqualIID(riid, &IID_IToggleProvider)) *out = &self->toggle;
    else if (IsEqualIID(riid, &IID_ISelectionItemProvider)) *out = &self->selection;
    else return E_NOINTERFACE;
    InterlockedIncrement(&self->refs);
    return S_OK;
}

static ULONG STDMETHODCALLTYPE element_add_ref(Element *self) { return InterlockedIncrement(&self->refs); }

static ULONG STDMETHODCALLTYPE element_release(Element *self) {
    LONG refs = InterlockedDecrement(&self->refs);
    if (refs == 0) {
        root_release(self->root);
        free(self);
    }
    return refs;
}

#define ELEMENT(pointer, field) CONTAINER(pointer, Element, field)

static HRESULT STDMETHODCALLTYPE es_query(IRawElementProviderSimple *This, REFIID riid, void **out) { return element_query(ELEMENT(This, simple), riid, out); }
static ULONG STDMETHODCALLTYPE es_add_ref(IRawElementProviderSimple *This) { return element_add_ref(ELEMENT(This, simple)); }
static ULONG STDMETHODCALLTYPE es_release(IRawElementProviderSimple *This) { return element_release(ELEMENT(This, simple)); }

static HRESULT STDMETHODCALLTYPE es_options(IRawElementProviderSimple *This, enum ProviderOptions *out) {
    (void)This;
    *out = ProviderOptions_ServerSideProvider | ProviderOptions_UseComThreading;
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE es_pattern(IRawElementProviderSimple *This, PATTERNID pattern, IUnknown **out) {
    Element *self = ELEMENT(This, simple);
    *out = NULL;
    int index = index_of(self->root, self->tag);
    if (index < 0) return UIA_E_ELEMENTNOTAVAILABLE;
    Item *item = &self->root->items[index];
    // A toggle button offers Toggle instead of Invoke, and a tab Select (as UI Automation's guidelines ask).
    if (pattern == UIA_TogglePatternId && item->toggle >= 0) {
        *out = (IUnknown *)&self->toggle;
    } else if (pattern == UIA_SelectionItemPatternId && item->selected >= 0) {
        *out = (IUnknown *)&self->selection;
    } else if (pattern == UIA_InvokePatternId && item->invokable && !item->hasPopup && item->toggle < 0 && item->selected < 0) {
        *out = (IUnknown *)&self->invoke;
    } else if (pattern == UIA_ExpandCollapsePatternId && item->hasPopup) {
        *out = (IUnknown *)&self->expandCollapse;
    } else {
        return S_OK;
    }
    InterlockedIncrement(&self->refs);
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE es_property(IRawElementProviderSimple *This, PROPERTYID property, VARIANT *out) {
    Element *self = ELEMENT(This, simple);
    VariantInit(out);
    int index = index_of(self->root, self->tag);
    if (index < 0) return UIA_E_ELEMENTNOTAVAILABLE;
    Item *item = &self->root->items[index];
    switch (property) {
    case UIA_AutomationIdPropertyId: set_string(out, item->automationId); break;
    case UIA_NamePropertyId: set_string(out, item->name); break;
    case UIA_HelpTextPropertyId: set_string(out, item->help); break;
    case UIA_AcceleratorKeyPropertyId: set_string(out, item->accelerator); break;
    case UIA_FrameworkIdPropertyId: set_string(out, L"Win32"); break;
    case UIA_ControlTypePropertyId: out->vt = VT_I4; out->lVal = item->controlType; break;
    case UIA_IsEnabledPropertyId: out->vt = VT_BOOL; out->boolVal = item->enabled ? VARIANT_TRUE : VARIANT_FALSE; break;
    case UIA_IsKeyboardFocusablePropertyId: out->vt = VT_BOOL; out->boolVal = VARIANT_FALSE; break;
    case UIA_IsControlElementPropertyId:
    case UIA_IsContentElementPropertyId: out->vt = VT_BOOL; out->boolVal = VARIANT_TRUE; break;
    case UIA_IsOffscreenPropertyId: out->vt = VT_BOOL; out->boolVal = IsIconic(self->root->hwnd) ? VARIANT_TRUE : VARIANT_FALSE; break;
    case UIA_ProcessIdPropertyId: {
        DWORD process = 0;
        GetWindowThreadProcessId(self->root->hwnd, &process);
        out->vt = VT_I4;
        out->lVal = (LONG)process;
        break;
    }
    default: break;
    }
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE es_host(IRawElementProviderSimple *This, IRawElementProviderSimple **out) {
    (void)This;
    *out = NULL;
    return S_OK;
}

static IRawElementProviderSimpleVtbl element_simple_vtbl = {
    es_query, es_add_ref, es_release, es_options, es_pattern, es_property, es_host,
};

// MARK: Element: IRawElementProviderFragment

static HRESULT STDMETHODCALLTYPE ef_query(IRawElementProviderFragment *This, REFIID riid, void **out) { return element_query(ELEMENT(This, fragment), riid, out); }
static ULONG STDMETHODCALLTYPE ef_add_ref(IRawElementProviderFragment *This) { return element_add_ref(ELEMENT(This, fragment)); }
static ULONG STDMETHODCALLTYPE ef_release(IRawElementProviderFragment *This) { return element_release(ELEMENT(This, fragment)); }

static HRESULT STDMETHODCALLTYPE ef_navigate(IRawElementProviderFragment *This, enum NavigateDirection direction,
                                             IRawElementProviderFragment **out) {
    Element *self = ELEMENT(This, fragment);
    *out = NULL;
    Root *root = self->root;
    int index = index_of(root, self->tag);
    if (index < 0) return UIA_E_ELEMENTNOTAVAILABLE;
    int target = -1;
    switch (direction) {
    case NavigateDirection_Parent:
        *out = &root->fragment;
        root_add_ref(root);
        return S_OK;
    case NavigateDirection_NextSibling: target = index + 1; break;
    case NavigateDirection_PreviousSibling: target = index - 1; break;
    default: return S_OK;
    }
    if (target < 0 || target >= root->count) return S_OK;
    Element *sibling = element_new(root, root->items[target].tag);
    if (!sibling) return E_OUTOFMEMORY;
    *out = &sibling->fragment;
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE ef_runtime_id(IRawElementProviderFragment *This, SAFEARRAY **out) {
    Element *self = ELEMENT(This, fragment);
    int id[2] = {UiaAppendRuntimeId, self->tag};
    *out = SafeArrayCreateVector(VT_I4, 0, 2);
    if (!*out) return E_OUTOFMEMORY;
    for (LONG i = 0; i < 2; i++) SafeArrayPutElement(*out, &i, &id[i]);
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE ef_bounds(IRawElementProviderFragment *This, struct UiaRect *out) {
    Element *self = ELEMENT(This, fragment);
    out->left = out->top = out->width = out->height = 0;
    int index = index_of(self->root, self->tag);
    if (index < 0) return UIA_E_ELEMENTNOTAVAILABLE;
    RECT rect = self->root->items[index].rect;
    POINT origin = {rect.left, rect.top};
    ClientToScreen(self->root->hwnd, &origin);
    out->left = origin.x;
    out->top = origin.y;
    out->width = rect.right - rect.left;
    out->height = rect.bottom - rect.top;
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE ef_embedded(IRawElementProviderFragment *This, SAFEARRAY **out) {
    (void)This;
    *out = NULL;
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE ef_focus(IRawElementProviderFragment *This) { (void)This; return S_OK; }

static HRESULT STDMETHODCALLTYPE ef_root(IRawElementProviderFragment *This, IRawElementProviderFragmentRoot **out) {
    Element *self = ELEMENT(This, fragment);
    *out = &self->root->fragmentRoot;
    root_add_ref(self->root);
    return S_OK;
}

static IRawElementProviderFragmentVtbl element_fragment_vtbl = {
    ef_query, ef_add_ref, ef_release, ef_navigate, ef_runtime_id, ef_bounds, ef_embedded, ef_focus, ef_root,
};

// MARK: Element: Invoke and ExpandCollapse

static HRESULT press(Element *self) {
    int index = index_of(self->root, self->tag);
    if (index < 0) return UIA_E_ELEMENTNOTAVAILABLE;
    if (!self->root->items[index].enabled) return UIA_E_ELEMENTNOTENABLED;
    // Posted, so a menu or dialog the item opens doesn't hold up the assistive tool's call.
    PostMessageW(self->root->hwnd, HERB_UIA_INVOKE_MESSAGE, (WPARAM)self->tag, 0);
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE ei_query(IInvokeProvider *This, REFIID riid, void **out) { return element_query(ELEMENT(This, invoke), riid, out); }
static ULONG STDMETHODCALLTYPE ei_add_ref(IInvokeProvider *This) { return element_add_ref(ELEMENT(This, invoke)); }
static ULONG STDMETHODCALLTYPE ei_release(IInvokeProvider *This) { return element_release(ELEMENT(This, invoke)); }
static HRESULT STDMETHODCALLTYPE ei_invoke(IInvokeProvider *This) { return press(ELEMENT(This, invoke)); }

static IInvokeProviderVtbl element_invoke_vtbl = { ei_query, ei_add_ref, ei_release, ei_invoke };

static HRESULT STDMETHODCALLTYPE ec_query(IExpandCollapseProvider *This, REFIID riid, void **out) { return element_query(ELEMENT(This, expandCollapse), riid, out); }
static ULONG STDMETHODCALLTYPE ec_add_ref(IExpandCollapseProvider *This) { return element_add_ref(ELEMENT(This, expandCollapse)); }
static ULONG STDMETHODCALLTYPE ec_release(IExpandCollapseProvider *This) { return element_release(ELEMENT(This, expandCollapse)); }
static HRESULT STDMETHODCALLTYPE ec_expand(IExpandCollapseProvider *This) { return press(ELEMENT(This, expandCollapse)); }
static HRESULT STDMETHODCALLTYPE ec_collapse(IExpandCollapseProvider *This) { (void)This; return S_OK; }
static HRESULT STDMETHODCALLTYPE ec_state(IExpandCollapseProvider *This, enum ExpandCollapseState *out) {
    (void)This;
    *out = ExpandCollapseState_Collapsed;  // the menu it opens is modal and closes before the next call
    return S_OK;
}

static IExpandCollapseProviderVtbl element_expand_vtbl = {
    ec_query, ec_add_ref, ec_release, ec_expand, ec_collapse, ec_state,
};

// MARK: Element: Toggle and SelectionItem

static HRESULT STDMETHODCALLTYPE et_query(IToggleProvider *This, REFIID riid, void **out) { return element_query(ELEMENT(This, toggle), riid, out); }
static ULONG STDMETHODCALLTYPE et_add_ref(IToggleProvider *This) { return element_add_ref(ELEMENT(This, toggle)); }
static ULONG STDMETHODCALLTYPE et_release(IToggleProvider *This) { return element_release(ELEMENT(This, toggle)); }
static HRESULT STDMETHODCALLTYPE et_toggle(IToggleProvider *This) { return press(ELEMENT(This, toggle)); }
static HRESULT STDMETHODCALLTYPE et_state(IToggleProvider *This, enum ToggleState *out) {
    Element *self = ELEMENT(This, toggle);
    *out = ToggleState_Off;
    int index = index_of(self->root, self->tag);
    if (index < 0) return UIA_E_ELEMENTNOTAVAILABLE;
    *out = self->root->items[index].toggle > 0 ? ToggleState_On : ToggleState_Off;
    return S_OK;
}

static IToggleProviderVtbl element_toggle_vtbl = { et_query, et_add_ref, et_release, et_toggle, et_state };

static HRESULT STDMETHODCALLTYPE el_query(ISelectionItemProvider *This, REFIID riid, void **out) { return element_query(ELEMENT(This, selection), riid, out); }
static ULONG STDMETHODCALLTYPE el_add_ref(ISelectionItemProvider *This) { return element_add_ref(ELEMENT(This, selection)); }
static ULONG STDMETHODCALLTYPE el_release(ISelectionItemProvider *This) { return element_release(ELEMENT(This, selection)); }
static HRESULT STDMETHODCALLTYPE el_select(ISelectionItemProvider *This) { return press(ELEMENT(This, selection)); }
static HRESULT STDMETHODCALLTYPE el_add(ISelectionItemProvider *This) { return press(ELEMENT(This, selection)); }
static HRESULT STDMETHODCALLTYPE el_remove(ISelectionItemProvider *This) { (void)This; return UIA_E_INVALIDOPERATION; }
static HRESULT STDMETHODCALLTYPE el_is_selected(ISelectionItemProvider *This, BOOL *out) {
    Element *self = ELEMENT(This, selection);
    *out = FALSE;
    int index = index_of(self->root, self->tag);
    if (index < 0) return UIA_E_ELEMENTNOTAVAILABLE;
    *out = self->root->items[index].selected > 0;
    return S_OK;
}
static HRESULT STDMETHODCALLTYPE el_container(ISelectionItemProvider *This, IRawElementProviderSimple **out) {
    Element *self = ELEMENT(This, selection);
    *out = &self->root->simple;
    root_add_ref(self->root);
    return S_OK;
}

static ISelectionItemProviderVtbl element_selection_vtbl = {
    el_query, el_add_ref, el_release, el_select, el_add, el_remove, el_is_selected, el_container,
};

static Element *element_new(Root *root, int tag) {
    Element *element = calloc(1, sizeof(Element));
    if (!element) return NULL;
    element->simple.lpVtbl = &element_simple_vtbl;
    element->fragment.lpVtbl = &element_fragment_vtbl;
    element->invoke.lpVtbl = &element_invoke_vtbl;
    element->expandCollapse.lpVtbl = &element_expand_vtbl;
    element->toggle.lpVtbl = &element_toggle_vtbl;
    element->selection.lpVtbl = &element_selection_vtbl;
    element->refs = 1;
    element->root = root;
    element->tag = tag;
    root_add_ref(root);
    return element;
}

// MARK: Root

#define ROOT(pointer, field) CONTAINER(pointer, Root, field)

static HRESULT root_query(Root *self, REFIID riid, void **out) {
    *out = NULL;
    if (IsEqualIID(riid, &IID_IUnknown) || IsEqualIID(riid, &IID_IRawElementProviderSimple)) *out = &self->simple;
    else if (IsEqualIID(riid, &IID_IRawElementProviderFragment)) *out = &self->fragment;
    else if (IsEqualIID(riid, &IID_IRawElementProviderFragmentRoot)) *out = &self->fragmentRoot;
    else return E_NOINTERFACE;
    root_add_ref(self);
    return S_OK;
}

static void root_release(Root *root) {
    if (InterlockedDecrement(&root->refs) == 0) {
        free_items(root->items, root->count);
        free(root);
    }
}

static HRESULT STDMETHODCALLTYPE rs_query(IRawElementProviderSimple *This, REFIID riid, void **out) { return root_query(ROOT(This, simple), riid, out); }
static ULONG STDMETHODCALLTYPE rs_add_ref(IRawElementProviderSimple *This) { return InterlockedIncrement(&ROOT(This, simple)->refs); }
static ULONG STDMETHODCALLTYPE rs_release(IRawElementProviderSimple *This) {
    Root *root = ROOT(This, simple);
    LONG refs = root->refs - 1;
    root_release(root);
    return refs;
}

static HRESULT STDMETHODCALLTYPE rs_pattern(IRawElementProviderSimple *This, PATTERNID pattern, IUnknown **out) {
    (void)This; (void)pattern;
    *out = NULL;
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE rs_property(IRawElementProviderSimple *This, PROPERTYID property, VARIANT *out) {
    (void)This; (void)property;
    VariantInit(out);  // the HWND's own provider answers for the window
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE rs_host(IRawElementProviderSimple *This, IRawElementProviderSimple **out) {
    Root *self = ROOT(This, simple);
    *out = NULL;
    if (!self->hwnd) return UIA_E_ELEMENTNOTAVAILABLE;
    return UiaHostProviderFromHwnd(self->hwnd, out);
}

static IRawElementProviderSimpleVtbl root_simple_vtbl = {
    rs_query, rs_add_ref, rs_release, es_options, rs_pattern, rs_property, rs_host,
};

static HRESULT STDMETHODCALLTYPE rf_query(IRawElementProviderFragment *This, REFIID riid, void **out) { return root_query(ROOT(This, fragment), riid, out); }
static ULONG STDMETHODCALLTYPE rf_add_ref(IRawElementProviderFragment *This) { return InterlockedIncrement(&ROOT(This, fragment)->refs); }
static ULONG STDMETHODCALLTYPE rf_release(IRawElementProviderFragment *This) {
    Root *root = ROOT(This, fragment);
    LONG refs = root->refs - 1;
    root_release(root);
    return refs;
}

static HRESULT STDMETHODCALLTYPE rf_navigate(IRawElementProviderFragment *This, enum NavigateDirection direction,
                                             IRawElementProviderFragment **out) {
    Root *self = ROOT(This, fragment);
    *out = NULL;
    if (!self->hwnd || self->count == 0) return S_OK;
    int index;
    if (direction == NavigateDirection_FirstChild) index = 0;
    else if (direction == NavigateDirection_LastChild) index = self->count - 1;
    else return S_OK;  // parent and siblings come from the HWND
    Element *child = element_new(self, self->items[index].tag);
    if (!child) return E_OUTOFMEMORY;
    *out = &child->fragment;
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE rf_runtime_id(IRawElementProviderFragment *This, SAFEARRAY **out) {
    (void)This;
    *out = NULL;  // hosted by its HWND, which has its own
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE rf_bounds(IRawElementProviderFragment *This, struct UiaRect *out) {
    (void)This;
    out->left = out->top = out->width = out->height = 0;  // the HWND's own
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE rf_root(IRawElementProviderFragment *This, IRawElementProviderFragmentRoot **out) {
    Root *self = ROOT(This, fragment);
    *out = &self->fragmentRoot;
    root_add_ref(self);
    return S_OK;
}

static IRawElementProviderFragmentVtbl root_fragment_vtbl = {
    rf_query, rf_add_ref, rf_release, rf_navigate, rf_runtime_id, rf_bounds, ef_embedded, ef_focus, rf_root,
};

static HRESULT STDMETHODCALLTYPE rr_query(IRawElementProviderFragmentRoot *This, REFIID riid, void **out) { return root_query(ROOT(This, fragmentRoot), riid, out); }
static ULONG STDMETHODCALLTYPE rr_add_ref(IRawElementProviderFragmentRoot *This) { return InterlockedIncrement(&ROOT(This, fragmentRoot)->refs); }
static ULONG STDMETHODCALLTYPE rr_release(IRawElementProviderFragmentRoot *This) {
    Root *root = ROOT(This, fragmentRoot);
    LONG refs = root->refs - 1;
    root_release(root);
    return refs;
}

static HRESULT STDMETHODCALLTYPE rr_from_point(IRawElementProviderFragmentRoot *This, double x, double y,
                                               IRawElementProviderFragment **out) {
    Root *self = ROOT(This, fragmentRoot);
    *out = NULL;
    if (!self->hwnd) return UIA_E_ELEMENTNOTAVAILABLE;
    POINT point = {(LONG)x, (LONG)y};
    ScreenToClient(self->hwnd, &point);
    // Last first: items listed later (a tab's close button) sit on top of earlier ones (its tab).
    for (int i = self->count - 1; i >= 0; i--) {
        if (PtInRect(&self->items[i].rect, point)) {
            Element *element = element_new(self, self->items[i].tag);
            if (!element) return E_OUTOFMEMORY;
            *out = &element->fragment;
            return S_OK;
        }
    }
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE rr_focus(IRawElementProviderFragmentRoot *This, IRawElementProviderFragment **out) {
    (void)This;
    *out = NULL;  // keyboard focus is in the terminal or editor below, a child window
    return S_OK;
}

static IRawElementProviderFragmentRootVtbl root_root_vtbl = { rr_query, rr_add_ref, rr_release, rr_from_point, rr_focus };

static Root *root_for(HWND hwnd, int create) {
    for (Root *root = roots; root; root = root->next)
        if (root->hwnd == hwnd) return root;
    if (!create) return NULL;
    Root *root = calloc(1, sizeof(Root));
    if (!root) return NULL;
    root->simple.lpVtbl = &root_simple_vtbl;
    root->fragment.lpVtbl = &root_fragment_vtbl;
    root->fragmentRoot.lpVtbl = &root_root_vtbl;
    root->refs = 1;  // the list's own reference
    root->hwnd = hwnd;
    root->next = roots;
    roots = root;
    return root;
}

// MARK: API

void herb_uia_set_items(void *window, const HerbUIAItem *items, int count) {
    HWND hwnd = (HWND)window;
    Root *root = root_for(hwnd, 1);
    if (!root) return;
    Item *copies = count > 0 ? calloc((size_t)count, sizeof(Item)) : NULL;
    if (count > 0 && !copies) return;
    for (int i = 0; i < count; i++) {
        copies[i].automationId = copy(items[i].automationId);
        copies[i].name = copy(items[i].name);
        copies[i].help = copy(items[i].help);
        copies[i].accelerator = copy(items[i].accelerator);
        copies[i].rect.left = items[i].left;
        copies[i].rect.top = items[i].top;
        copies[i].rect.right = items[i].right;
        copies[i].rect.bottom = items[i].bottom;
        copies[i].controlType = items[i].controlType;
        copies[i].enabled = items[i].enabled;
        copies[i].hasPopup = items[i].hasPopup;
        copies[i].invokable = items[i].invokable;
        copies[i].tag = items[i].tag;
        copies[i].toggle = items[i].toggle;
        copies[i].selected = items[i].selected;
    }
    // Screen readers announce a button turning on or off, and a newly selected tab, from these events.
    if (UiaClientsAreListening()) {
        for (int i = 0; i < count; i++) {
            int old = index_of(root, copies[i].tag);
            if (old < 0) continue;
            Item *before = &root->items[old];
            if (copies[i].toggle >= 0 && before->toggle >= 0 && copies[i].toggle != before->toggle) {
                Element *element = element_new(root, copies[i].tag);
                if (!element) continue;
                VARIANT was, now;
                VariantInit(&was); VariantInit(&now);
                was.vt = now.vt = VT_I4;
                was.lVal = before->toggle > 0 ? ToggleState_On : ToggleState_Off;
                now.lVal = copies[i].toggle > 0 ? ToggleState_On : ToggleState_Off;
                UiaRaiseAutomationPropertyChangedEvent(&element->simple, UIA_ToggleToggleStatePropertyId, was, now);
                element_release(element);
            }
            if (copies[i].selected > 0 && before->selected == 0) {
                Element *element = element_new(root, copies[i].tag);
                if (!element) continue;
                UiaRaiseAutomationEvent(&element->simple, UIA_SelectionItem_ElementSelectedEventId);
                element_release(element);
            }
        }
    }
    free_items(root->items, root->count);
    root->items = copies;
    root->count = count;
}

int herb_uia_get_object(void *window, uintptr_t wParam, intptr_t lParam, intptr_t *result) {
    HWND hwnd = (HWND)window;
    if ((LONG)lParam != UiaRootObjectId) return 0;
    Root *root = root_for(hwnd, 1);
    if (!root) return 0;
    *result = (intptr_t)UiaReturnRawElementProvider(hwnd, (WPARAM)wParam, (LPARAM)lParam, &root->simple);
    return 1;
}

void herb_uia_window_destroyed(void *window) {
    HWND hwnd = (HWND)window;
    Root **link = &roots;
    while (*link && (*link)->hwnd != hwnd) link = &(*link)->next;
    Root *root = *link;
    if (!root) return;
    *link = root->next;
    UiaReturnRawElementProvider(hwnd, 0, 0, NULL);
    UiaDisconnectProvider(&root->simple);
    root->hwnd = NULL;
    free_items(root->items, root->count);
    root->items = NULL;
    root->count = 0;
    root_release(root);
}

// The terminal's text provider.
#include "herb_text_part.h"
