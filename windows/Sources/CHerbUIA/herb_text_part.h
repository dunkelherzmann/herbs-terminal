// Part of herb_uia.c (included at its end, not compiled alone): Windows' UIAutomationCore.h defines its constants
// in every C file that includes it, so only one file of the target may.
//
// UI Automation for the terminal: the screen's text with UIA's Text pattern, so screen readers can read it by
// character, word and line, and announcements of new output. See include/herb_uia.h.
//
// The app hands over the visible screen as text (one line per row, joined with "\n") only when an assistive tool
// asks for it: it marks the text stale on every change, and the provider fetches a fresh copy through a callback.
// Each range keeps the copy it was made from, so a tool's ranges stay consistent while the screen changes.

#include <windows.h>
#include <ole2.h>
#include <oleauto.h>
#include <uiautomation.h>
#include <stddef.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>
#include <wctype.h>

#include "herb_uia.h"


typedef struct Snapshot {
    LONG refs;
    wchar_t *text;
    int length;
    int *lineStarts;  // the offset of each row's first character
    int lineCount;
} Snapshot;

typedef struct Pane {
    IRawElementProviderSimple simple;
    ITextProvider text;
    LONG refs;
    HWND hwnd;  // NULL once the window is gone
    wchar_t *name;
    Snapshot *snapshot;
    int stale;
    int caret;  // offset of the cursor in the snapshot
    int left, top, cellWidth, cellHeight;
    struct Pane *next;
} Pane;

typedef struct Range {
    ITextRangeProvider iface;
    LONG refs;
    Pane *pane;
    Snapshot *snapshot;
    int start, end;
} Range;

static Pane *panes;
static void (*refresh_callback)(void *hwnd);

// MARK: Snapshots

static void snapshot_release(Snapshot *snapshot) {
    if (snapshot && InterlockedDecrement(&snapshot->refs) == 0) {
        free(snapshot->text);
        free(snapshot->lineStarts);
        free(snapshot);
    }
}

static Snapshot *snapshot_new(const unsigned short *text, int length) {
    Snapshot *snapshot = calloc(1, sizeof(Snapshot));
    if (!snapshot) return NULL;
    snapshot->refs = 1;
    snapshot->text = calloc((size_t)length + 1, sizeof(wchar_t));
    int lines = 1;
    for (int i = 0; i < length; i++) if (text[i] == L'\n') lines++;
    snapshot->lineStarts = calloc((size_t)lines, sizeof(int));
    if (!snapshot->text || !snapshot->lineStarts) { snapshot_release(snapshot); return NULL; }
    if (length > 0) memcpy(snapshot->text, text, (size_t)length * sizeof(wchar_t));
    snapshot->length = length;
    snapshot->lineCount = 1;
    for (int i = 0; i < length; i++)
        if (text[i] == L'\n') snapshot->lineStarts[snapshot->lineCount++] = i + 1;
    return snapshot;
}

static int line_of(const Snapshot *s, int offset) {
    int line = 0;
    while (line + 1 < s->lineCount && s->lineStarts[line + 1] <= offset) line++;
    return line;
}

/// The end of a row's text, before its "\n".
static int line_end(const Snapshot *s, int line) {
    return line + 1 < s->lineCount ? s->lineStarts[line + 1] - 1 : s->length;
}

// MARK: Text units

static enum TextUnit normalize_unit(enum TextUnit unit) {
    switch (unit) {
    case TextUnit_Character: return TextUnit_Character;
    case TextUnit_Format:
    case TextUnit_Word: return TextUnit_Word;
    case TextUnit_Line:
    case TextUnit_Paragraph: return TextUnit_Line;
    default: return TextUnit_Document;
    }
}

static int is_space(wchar_t c) { return c == L' ' || c == L'\n' || c == L'\t' || c == 0; }

static int is_boundary(const Snapshot *s, int offset, enum TextUnit unit) {
    if (offset <= 0 || offset >= s->length) return 1;
    switch (unit) {
    case TextUnit_Character: return 1;
    case TextUnit_Word:
        if (s->text[offset - 1] == L'\n') return 1;
        return !is_space(s->text[offset]) && is_space(s->text[offset - 1]);
    case TextUnit_Line: return s->text[offset - 1] == L'\n';
    default: return 0;
    }
}

static int next_boundary(const Snapshot *s, int offset, enum TextUnit unit) {
    int p = offset + 1;
    while (p < s->length && !is_boundary(s, p, unit)) p++;
    return p > s->length ? s->length : p;
}

static int previous_boundary(const Snapshot *s, int offset, enum TextUnit unit) {
    int p = offset - 1;
    while (p > 0 && !is_boundary(s, p, unit)) p--;
    return p < 0 ? 0 : p;
}

/// The start of the unit holding `offset`.
static int unit_start(const Snapshot *s, int offset, enum TextUnit unit) {
    return is_boundary(s, offset, unit) && offset < s->length ? offset : previous_boundary(s, offset, unit);
}

// MARK: Panes

static void pane_add_ref(Pane *pane) { InterlockedIncrement(&pane->refs); }

static void pane_release(Pane *pane) {
    if (InterlockedDecrement(&pane->refs) == 0) {
        free(pane->name);
        snapshot_release(pane->snapshot);
        free(pane);
    }
}

/// The current text, fetched from the app when it changed since the last time.
static Snapshot *current(Pane *pane) {
    if (pane->hwnd && (pane->stale || !pane->snapshot) && refresh_callback) refresh_callback(pane->hwnd);
    if (!pane->snapshot) pane->snapshot = snapshot_new((const unsigned short *)L"", 0);
    return pane->snapshot;
}

static Pane *pane_for(HWND hwnd, int create) {
    for (Pane *pane = panes; pane; pane = pane->next)
        if (pane->hwnd == hwnd) return pane;
    if (!create) return NULL;
    Pane *pane = calloc(1, sizeof(Pane));
    if (!pane) return NULL;
    extern IRawElementProviderSimpleVtbl herb_pane_simple_vtbl;
    extern ITextProviderVtbl herb_pane_text_vtbl;
    pane->simple.lpVtbl = &herb_pane_simple_vtbl;
    pane->text.lpVtbl = &herb_pane_text_vtbl;
    pane->refs = 1;  // the list's own reference
    pane->hwnd = hwnd;
    pane->stale = 1;
    pane->next = panes;
    panes = pane;
    return pane;
}

// MARK: Ranges

extern ITextRangeProviderVtbl herb_range_vtbl;

static Range *range_new(Pane *pane, Snapshot *snapshot, int start, int end) {
    Range *range = calloc(1, sizeof(Range));
    if (!range) return NULL;
    range->iface.lpVtbl = &herb_range_vtbl;
    range->refs = 1;
    range->pane = pane;
    pane_add_ref(pane);
    range->snapshot = snapshot;
    InterlockedIncrement(&snapshot->refs);
    if (start < 0) start = 0;
    if (end > snapshot->length) end = snapshot->length;
    if (start > end) start = end;
    range->start = start;
    range->end = end;
    return range;
}

static Range *own_range(ITextRangeProvider *other) {
    return other && other->lpVtbl == &herb_range_vtbl ? CONTAINER(other, Range, iface) : NULL;
}

static HRESULT STDMETHODCALLTYPE r_query(ITextRangeProvider *This, REFIID riid, void **out) {
    *out = NULL;
    if (!IsEqualIID(riid, &IID_IUnknown) && !IsEqualIID(riid, &IID_ITextRangeProvider)) return E_NOINTERFACE;
    *out = This;
    InterlockedIncrement(&CONTAINER(This, Range, iface)->refs);
    return S_OK;
}

static ULONG STDMETHODCALLTYPE r_add_ref(ITextRangeProvider *This) { return InterlockedIncrement(&CONTAINER(This, Range, iface)->refs); }

static ULONG STDMETHODCALLTYPE r_release(ITextRangeProvider *This) {
    Range *self = CONTAINER(This, Range, iface);
    LONG refs = InterlockedDecrement(&self->refs);
    if (refs == 0) {
        snapshot_release(self->snapshot);
        pane_release(self->pane);
        free(self);
    }
    return refs;
}

static HRESULT STDMETHODCALLTYPE r_clone(ITextRangeProvider *This, ITextRangeProvider **out) {
    Range *self = CONTAINER(This, Range, iface);
    Range *copy = range_new(self->pane, self->snapshot, self->start, self->end);
    *out = copy ? &copy->iface : NULL;
    return copy ? S_OK : E_OUTOFMEMORY;
}

static HRESULT STDMETHODCALLTYPE r_compare(ITextRangeProvider *This, ITextRangeProvider *other, BOOL *out) {
    Range *self = CONTAINER(This, Range, iface), *them = own_range(other);
    *out = them && them->pane == self->pane && them->start == self->start && them->end == self->end;
    return S_OK;
}

static int endpoint(const Range *range, enum TextPatternRangeEndpoint which) {
    return which == TextPatternRangeEndpoint_Start ? range->start : range->end;
}

static void set_endpoint(Range *range, enum TextPatternRangeEndpoint which, int value) {
    if (value < 0) value = 0;
    if (value > range->snapshot->length) value = range->snapshot->length;
    if (which == TextPatternRangeEndpoint_Start) {
        range->start = value;
        if (range->end < value) range->end = value;
    } else {
        range->end = value;
        if (range->start > value) range->start = value;
    }
}

static HRESULT STDMETHODCALLTYPE r_compare_endpoints(ITextRangeProvider *This, enum TextPatternRangeEndpoint which,
                                                     ITextRangeProvider *other, enum TextPatternRangeEndpoint theirs, int *out) {
    Range *self = CONTAINER(This, Range, iface), *them = own_range(other);
    if (!them) return E_INVALIDARG;
    *out = endpoint(self, which) - endpoint(them, theirs);
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE r_expand(ITextRangeProvider *This, enum TextUnit unit) {
    Range *self = CONTAINER(This, Range, iface);
    const Snapshot *s = self->snapshot;
    unit = normalize_unit(unit);
    if (unit == TextUnit_Document) { self->start = 0; self->end = s->length; return S_OK; }
    int start = unit_start(s, self->start, unit);
    self->start = start;
    self->end = start < s->length ? next_boundary(s, start, unit) : s->length;
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE r_find_attribute(ITextRangeProvider *This, TEXTATTRIBUTEID attribute, VARIANT value, BOOL backward,
                                                  ITextRangeProvider **out) {
    (void)This; (void)attribute; (void)value; (void)backward;
    *out = NULL;  // the terminal's text carries no attributes here
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE r_find_text(ITextRangeProvider *This, BSTR text, BOOL backward, BOOL ignoreCase, ITextRangeProvider **out) {
    Range *self = CONTAINER(This, Range, iface);
    *out = NULL;
    int needle = text ? (int)SysStringLen(text) : 0;
    if (needle == 0) return S_OK;
    const wchar_t *hay = self->snapshot->text;
    int found = -1;
    for (int p = self->start; p + needle <= self->end; p++) {
        int match = ignoreCase ? _wcsnicmp(hay + p, text, (size_t)needle) == 0 : wcsncmp(hay + p, text, (size_t)needle) == 0;
        if (match) { found = p; if (!backward) break; }
    }
    if (found < 0) return S_OK;
    Range *range = range_new(self->pane, self->snapshot, found, found + needle);
    if (!range) return E_OUTOFMEMORY;
    *out = &range->iface;
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE r_attribute(ITextRangeProvider *This, TEXTATTRIBUTEID attribute, VARIANT *out) {
    (void)This;
    VariantInit(out);
    if (attribute == UIA_IsReadOnlyAttributeId) {
        out->vt = VT_BOOL;
        out->boolVal = VARIANT_TRUE;  // typing goes to the program, not into this text
        return S_OK;
    }
    out->vt = VT_UNKNOWN;
    return UiaGetReservedNotSupportedValue(&out->punkVal);
}

static HRESULT STDMETHODCALLTYPE r_rectangles(ITextRangeProvider *This, SAFEARRAY **out) {
    Range *self = CONTAINER(This, Range, iface);
    Pane *pane = self->pane;
    const Snapshot *s = self->snapshot;
    *out = NULL;
    if (!pane->hwnd) return UIA_E_ELEMENTNOTAVAILABLE;
    int first = line_of(s, self->start), last = line_of(s, self->end);
    double *values = calloc((size_t)(last - first + 1) * 4, sizeof(double));
    if (!values) return E_OUTOFMEMORY;
    int count = 0;
    for (int line = first; line <= last; line++) {
        int from = self->start > s->lineStarts[line] ? self->start : s->lineStarts[line];
        int to = self->end < line_end(s, line) ? self->end : line_end(s, line);
        int columnFrom = from - s->lineStarts[line], columnTo = to - s->lineStarts[line];
        if (columnTo <= columnFrom) {
            if (self->start != self->end) continue;
            columnTo = columnFrom + 1;  // a caret: one cell wide
        }
        POINT origin = {pane->left + columnFrom * pane->cellWidth, pane->top + line * pane->cellHeight};
        ClientToScreen(pane->hwnd, &origin);
        values[count * 4] = origin.x;
        values[count * 4 + 1] = origin.y;
        values[count * 4 + 2] = (double)(columnTo - columnFrom) * pane->cellWidth;
        values[count * 4 + 3] = pane->cellHeight;
        count++;
    }
    *out = SafeArrayCreateVector(VT_R8, 0, (ULONG)count * 4);
    if (*out) for (LONG i = 0; i < count * 4; i++) SafeArrayPutElement(*out, &i, &values[i]);
    free(values);
    return *out ? S_OK : E_OUTOFMEMORY;
}

static HRESULT STDMETHODCALLTYPE r_enclosing(ITextRangeProvider *This, IRawElementProviderSimple **out) {
    Range *self = CONTAINER(This, Range, iface);
    *out = &self->pane->simple;
    pane_add_ref(self->pane);
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE r_text(ITextRangeProvider *This, int maxLength, BSTR *out) {
    Range *self = CONTAINER(This, Range, iface);
    int length = self->end - self->start;
    if (maxLength >= 0 && length > maxLength) length = maxLength;
    *out = SysAllocStringLen(self->snapshot->text + self->start, (UINT)length);
    return *out ? S_OK : E_OUTOFMEMORY;
}

static HRESULT STDMETHODCALLTYPE r_move(ITextRangeProvider *This, enum TextUnit unit, int count, int *out) {
    Range *self = CONTAINER(This, Range, iface);
    const Snapshot *s = self->snapshot;
    *out = 0;
    unit = normalize_unit(unit);
    int degenerate = self->start == self->end;
    if (count == 0) return S_OK;
    if (unit == TextUnit_Document) {
        // There's one document: moving forward ends at its end, backward at its start.
        int target = count > 0 ? s->length : 0;
        if (self->start != target) *out = count > 0 ? 1 : -1;
        self->start = target;
        self->end = degenerate || count > 0 ? target : s->length;
        return S_OK;
    }
    int position = unit_start(s, self->start, unit);
    if (count > 0) {
        while (*out < count) {
            int next = next_boundary(s, position, unit);
            if (next >= s->length) break;
            position = next;
            (*out)++;
        }
    } else {
        if (position < self->start) { (*out)--; }  // to the start of the unit holding the range
        while (*out > count && position > 0) {
            position = previous_boundary(s, position, unit);
            (*out)--;
        }
    }
    self->start = position;
    self->end = degenerate ? position : next_boundary(s, position, unit);
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE r_move_endpoint(ITextRangeProvider *This, enum TextPatternRangeEndpoint which, enum TextUnit unit,
                                                 int count, int *out) {
    Range *self = CONTAINER(This, Range, iface);
    const Snapshot *s = self->snapshot;
    *out = 0;
    unit = normalize_unit(unit);
    int position = endpoint(self, which);
    if (unit == TextUnit_Document) {
        int target = count > 0 ? s->length : 0;
        if (count != 0 && position != target) { *out = count > 0 ? 1 : -1; position = target; }
    } else if (count > 0) {
        while (*out < count && position < s->length) { position = next_boundary(s, position, unit); (*out)++; }
    } else {
        while (*out > count && position > 0) { position = previous_boundary(s, position, unit); (*out)--; }
    }
    set_endpoint(self, which, position);
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE r_move_endpoint_by_range(ITextRangeProvider *This, enum TextPatternRangeEndpoint which,
                                                          ITextRangeProvider *other, enum TextPatternRangeEndpoint theirs) {
    Range *self = CONTAINER(This, Range, iface), *them = own_range(other);
    if (!them) return E_INVALIDARG;
    set_endpoint(self, which, endpoint(them, theirs));
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE r_select(ITextRangeProvider *This) { (void)This; return S_OK; }
static HRESULT STDMETHODCALLTYPE r_add_selection(ITextRangeProvider *This) { (void)This; return UIA_E_INVALIDOPERATION; }
static HRESULT STDMETHODCALLTYPE r_remove_selection(ITextRangeProvider *This) { (void)This; return UIA_E_INVALIDOPERATION; }
static HRESULT STDMETHODCALLTYPE r_scroll(ITextRangeProvider *This, BOOL top) { (void)This; (void)top; return S_OK; }

static HRESULT STDMETHODCALLTYPE r_children(ITextRangeProvider *This, SAFEARRAY **out) {
    (void)This;
    *out = SafeArrayCreateVector(VT_UNKNOWN, 0, 0);
    return *out ? S_OK : E_OUTOFMEMORY;
}

ITextRangeProviderVtbl herb_range_vtbl = {
    r_query, r_add_ref, r_release, r_clone, r_compare, r_compare_endpoints, r_expand, r_find_attribute, r_find_text,
    r_attribute, r_rectangles, r_enclosing, r_text, r_move, r_move_endpoint, r_move_endpoint_by_range, r_select,
    r_add_selection, r_remove_selection, r_scroll, r_children,
};

// MARK: Pane: IRawElementProviderSimple

static HRESULT pane_query(Pane *self, REFIID riid, void **out) {
    *out = NULL;
    if (IsEqualIID(riid, &IID_IUnknown) || IsEqualIID(riid, &IID_IRawElementProviderSimple)) *out = &self->simple;
    else if (IsEqualIID(riid, &IID_ITextProvider)) *out = &self->text;
    else return E_NOINTERFACE;
    pane_add_ref(self);
    return S_OK;
}

#define PANE(pointer, field) CONTAINER(pointer, Pane, field)

static HRESULT STDMETHODCALLTYPE ps_query(IRawElementProviderSimple *This, REFIID riid, void **out) { return pane_query(PANE(This, simple), riid, out); }
static ULONG STDMETHODCALLTYPE ps_add_ref(IRawElementProviderSimple *This) { return InterlockedIncrement(&PANE(This, simple)->refs); }
static ULONG STDMETHODCALLTYPE ps_release(IRawElementProviderSimple *This) {
    Pane *self = PANE(This, simple);
    LONG refs = self->refs - 1;
    pane_release(self);
    return refs;
}

static HRESULT STDMETHODCALLTYPE ps_options(IRawElementProviderSimple *This, enum ProviderOptions *out) {
    (void)This;
    *out = ProviderOptions_ServerSideProvider | ProviderOptions_UseComThreading;
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE ps_pattern(IRawElementProviderSimple *This, PATTERNID pattern, IUnknown **out) {
    Pane *self = PANE(This, simple);
    *out = NULL;
    if (!self->hwnd) return UIA_E_ELEMENTNOTAVAILABLE;
    if (pattern == UIA_TextPatternId) {
        *out = (IUnknown *)&self->text;
        pane_add_ref(self);
    }
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE ps_property(IRawElementProviderSimple *This, PROPERTYID property, VARIANT *out) {
    Pane *self = PANE(This, simple);
    VariantInit(out);
    if (!self->hwnd) return UIA_E_ELEMENTNOTAVAILABLE;
    switch (property) {
    case UIA_ControlTypePropertyId: out->vt = VT_I4; out->lVal = UIA_DocumentControlTypeId; break;
    case UIA_LocalizedControlTypePropertyId: out->vt = VT_BSTR; out->bstrVal = SysAllocString(L"terminal"); break;
    case UIA_NamePropertyId:
        current(self);  // the name comes with the text
        if (self->name) { out->vt = VT_BSTR; out->bstrVal = SysAllocString(self->name); } break;
    case UIA_AutomationIdPropertyId: out->vt = VT_BSTR; out->bstrVal = SysAllocString(L"terminal"); break;
    case UIA_IsKeyboardFocusablePropertyId: out->vt = VT_BOOL; out->boolVal = VARIANT_TRUE; break;
    default: break;
    }
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE ps_host(IRawElementProviderSimple *This, IRawElementProviderSimple **out) {
    Pane *self = PANE(This, simple);
    *out = NULL;
    return self->hwnd ? UiaHostProviderFromHwnd(self->hwnd, out) : UIA_E_ELEMENTNOTAVAILABLE;
}

IRawElementProviderSimpleVtbl herb_pane_simple_vtbl = { ps_query, ps_add_ref, ps_release, ps_options, ps_pattern, ps_property, ps_host };

// MARK: Pane: ITextProvider

static HRESULT STDMETHODCALLTYPE pt_query(ITextProvider *This, REFIID riid, void **out) { return pane_query(PANE(This, text), riid, out); }
static ULONG STDMETHODCALLTYPE pt_add_ref(ITextProvider *This) { return InterlockedIncrement(&PANE(This, text)->refs); }
static ULONG STDMETHODCALLTYPE pt_release(ITextProvider *This) {
    Pane *self = PANE(This, text);
    LONG refs = self->refs - 1;
    pane_release(self);
    return refs;
}

static HRESULT one_range(Range *range, SAFEARRAY **out) {
    *out = NULL;
    if (!range) return E_OUTOFMEMORY;
    *out = SafeArrayCreateVector(VT_UNKNOWN, 0, 1);
    LONG index = 0;
    if (*out) SafeArrayPutElement(*out, &index, (IUnknown *)&range->iface);  // takes its own reference
    r_release(&range->iface);
    return *out ? S_OK : E_OUTOFMEMORY;
}

static HRESULT STDMETHODCALLTYPE pt_selection(ITextProvider *This, SAFEARRAY **out) {
    Pane *self = PANE(This, text);
    if (!self->hwnd) return UIA_E_ELEMENTNOTAVAILABLE;
    Snapshot *s = current(self);
    return one_range(range_new(self, s, self->caret, self->caret), out);  // the cursor, as a caret
}

static HRESULT STDMETHODCALLTYPE pt_visible(ITextProvider *This, SAFEARRAY **out) {
    Pane *self = PANE(This, text);
    if (!self->hwnd) return UIA_E_ELEMENTNOTAVAILABLE;
    Snapshot *s = current(self);
    return one_range(range_new(self, s, 0, s->length), out);
}

static HRESULT STDMETHODCALLTYPE pt_from_child(ITextProvider *This, IRawElementProviderSimple *child, ITextRangeProvider **out) {
    (void)This; (void)child;
    *out = NULL;
    return E_INVALIDARG;  // the terminal has no children
}

static HRESULT STDMETHODCALLTYPE pt_from_point(ITextProvider *This, struct UiaPoint point, ITextRangeProvider **out) {
    Pane *self = PANE(This, text);
    *out = NULL;
    if (!self->hwnd) return UIA_E_ELEMENTNOTAVAILABLE;
    Snapshot *s = current(self);
    POINT client = {(LONG)point.x, (LONG)point.y};
    ScreenToClient(self->hwnd, &client);
    int line = self->cellHeight > 0 ? (client.y - self->top) / self->cellHeight : 0;
    int column = self->cellWidth > 0 ? (client.x - self->left) / self->cellWidth : 0;
    if (line < 0) line = 0;
    if (line >= s->lineCount) line = s->lineCount - 1;
    if (column < 0) column = 0;
    int offset = s->lineStarts[line] + column;
    if (offset > line_end(s, line)) offset = line_end(s, line);
    Range *range = range_new(self, s, offset, offset);
    if (!range) return E_OUTOFMEMORY;
    *out = &range->iface;
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE pt_document(ITextProvider *This, ITextRangeProvider **out) {
    Pane *self = PANE(This, text);
    *out = NULL;
    if (!self->hwnd) return UIA_E_ELEMENTNOTAVAILABLE;
    Snapshot *s = current(self);
    Range *range = range_new(self, s, 0, s->length);
    if (!range) return E_OUTOFMEMORY;
    *out = &range->iface;
    return S_OK;
}

static HRESULT STDMETHODCALLTYPE pt_supported(ITextProvider *This, enum SupportedTextSelection *out) {
    (void)This;
    *out = SupportedTextSelection_None;
    return S_OK;
}

ITextProviderVtbl herb_pane_text_vtbl = {
    pt_query, pt_add_ref, pt_release, pt_selection, pt_visible, pt_from_child, pt_from_point, pt_document, pt_supported,
};

// MARK: API

void herb_uia_text_register(void (*refresh)(void *hwnd)) { refresh_callback = refresh; }

int herb_uia_listening(void) { return UiaClientsAreListening() ? 1 : 0; }

void herb_uia_text_set(void *window, const unsigned short *name, const unsigned short *text, int length, int caret,
                       int left, int top, int cellWidth, int cellHeight) {
    Pane *pane = pane_for((HWND)window, 1);
    if (!pane) return;
    Snapshot *snapshot = snapshot_new(text, length);
    if (!snapshot) return;
    snapshot_release(pane->snapshot);
    pane->snapshot = snapshot;
    free(pane->name);
    pane->name = name ? _wcsdup((const wchar_t *)name) : NULL;
    pane->caret = caret < 0 ? 0 : (caret > length ? length : caret);
    pane->left = left;
    pane->top = top;
    pane->cellWidth = cellWidth;
    pane->cellHeight = cellHeight;
    pane->stale = 0;
}

void herb_uia_text_changed(void *window, int textChanged) {
    Pane *pane = pane_for((HWND)window, 0);
    if (!pane) return;  // no assistive tool has asked for this terminal yet
    pane->stale = 1;
    if (!UiaClientsAreListening()) return;
    UiaRaiseAutomationEvent(&pane->simple, textChanged ? UIA_Text_TextChangedEventId : UIA_Text_TextSelectionChangedEventId);
}

void herb_uia_text_announce(void *window, const unsigned short *text) {
    typedef HRESULT (WINAPI *Notify)(IRawElementProviderSimple *, int, int, BSTR, BSTR);
    static Notify notify;
    static int looked;
    if (!looked) {
        looked = 1;
        HMODULE module = GetModuleHandleW(L"uiautomationcore.dll");
        if (module) notify = (Notify)(void *)GetProcAddress(module, "UiaRaiseNotificationEvent");
    }
    Pane *pane = pane_for((HWND)window, 1);
    if (!pane || !notify || !text || !UiaClientsAreListening()) return;
    BSTR display = SysAllocString((const wchar_t *)text), activity = SysAllocString(L"HerbsTerminal.output");
    // NotificationKind_Other, NotificationProcessing_All: every piece of output is read, in order.
    if (display && activity) notify(&pane->simple, 4, 2, display, activity);
    SysFreeString(display);
    SysFreeString(activity);
}

int herb_uia_text_get_object(void *window, uintptr_t wParam, intptr_t lParam, intptr_t *result) {
    HWND hwnd = (HWND)window;
    if ((LONG)lParam != UiaRootObjectId) return 0;
    Pane *pane = pane_for(hwnd, 1);
    if (!pane) return 0;
    *result = (intptr_t)UiaReturnRawElementProvider(hwnd, (WPARAM)wParam, (LPARAM)lParam, &pane->simple);
    return 1;
}

void herb_uia_text_destroyed(void *window) {
    HWND hwnd = (HWND)window;
    Pane **link = &panes;
    while (*link && (*link)->hwnd != hwnd) link = &(*link)->next;
    Pane *pane = *link;
    if (!pane) return;
    *link = pane->next;
    UiaReturnRawElementProvider(hwnd, 0, 0, NULL);
    UiaDisconnectProvider(&pane->simple);
    pane->hwnd = NULL;
    pane_release(pane);
}
