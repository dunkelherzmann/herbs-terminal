#ifndef HERB_H
#define HERB_H

#include <gtk/gtk.h>
#include <adwaita.h>
#include <vte/vte.h>

/// One signal handler: `data` is the Swift closure box, `values[0]` the emitting instance.
typedef void (*HerbCallback)(void *data, GValue *return_value, guint count, const GValue *values);
typedef void (*HerbRelease)(void *data);

/// Connects a GObject signal to a Swift closure through a generic marshaller; `release` frees the box when the
/// handler goes away (disconnected, or the object finalized).
gulong herb_connect(gpointer instance, const char *signal, HerbCallback callback, void *data, HerbRelease release,
                    gboolean after);

/// A GClosure for the same Swift callback, for GtkShortcut actions and the like.
GClosure *herb_closure(HerbCallback callback, void *data, HerbRelease release);

/// Runs libdispatch's main queue (Swift's MainActor) from the GLib main loop.
void herb_integrate_dispatch(void);

/// A GLib timeout or idle that calls back until the callback returns FALSE.
guint herb_timeout(guint milliseconds, gboolean (*callback)(void *), void *data, HerbRelease release);
guint herb_idle(gboolean (*callback)(void *), void *data, HerbRelease release);

void herb_set_bool(gpointer object, const char *name, gboolean value);
void herb_set_int(gpointer object, const char *name, gint value);
void herb_set_uint(gpointer object, const char *name, guint value);
void herb_set_double(gpointer object, const char *name, gdouble value);
void herb_set_string(gpointer object, const char *name, const char *value);
void herb_set_object(gpointer object, const char *name, gpointer value);
gboolean herb_get_bool(gpointer object, const char *name);
char *herb_get_string(gpointer object, const char *name);

/// Spawns argv in the terminal's PTY; the child's pid comes back through `done` (or -1 with a message).
typedef void (*HerbSpawned)(void *data, GPid pid, const char *error);
/// `host` leaves the PTY free for a shell on the host (through flatpak-spawn) to take as its controlling terminal.
void herb_vte_spawn(VteTerminal *terminal, const char *directory, char **argv, char **envv, gboolean host, HerbSpawned done,
                    void *data);

/// A clipboard provider for file lists whose text is produced only when another app pastes it: the
/// callback returns a newline-separated list of file URIs (newly allocated, freed here) for the mime type.
typedef char *(*HerbProvide)(void *data, const char *mime_type);
GdkContentProvider *herb_lazy_files_provider(HerbProvide provide, void *data, HerbRelease release);

/// Reads a file list or text from the clipboard; `done` receives newline-separated URIs or the text (NULL when
/// there is none).
typedef void (*HerbReceived)(void *data, const char *text);
void herb_clipboard_read_files(GdkClipboard *clipboard, HerbReceived done, void *data);
void herb_clipboard_read_text(GdkClipboard *clipboard, HerbReceived done, void *data);

/// Puts local files on the clipboard, as file managers do: a file list, a URI list and GNOME's copied-files
/// format, which also says whether they were cut. `paths` is newline-separated.
void herb_clipboard_set_files(GdkClipboard *clipboard, const char *paths, gboolean cut);

/// Whether the clipboard currently offers files (a URI list).
gboolean herb_clipboard_has_files(GdkClipboard *clipboard);

/// Values out of a GValue array, for signal parameters.
gpointer herb_value_pointer(const GValue *values, guint index);
gint herb_value_int(const GValue *values, guint index);
guint herb_value_uint(const GValue *values, guint index);
gdouble herb_value_double(const GValue *values, guint index);
const char *herb_value_string(const GValue *values, guint index);
gboolean herb_value_bool(const GValue *values, guint index);
void herb_return_bool(GValue *value, gboolean result);
/// Hands a new object reference back as a signal's return value (e.g. a drag source's content).
void herb_return_pointer(GValue *value, gpointer object);

/// The dropped file list of a GtkDropTarget value (GdkFileList), as newline-separated paths.
char *herb_drop_paths(const GValue *value);

/// GType constants that are macros in C.
GType herb_type_file_list(void);
GType herb_type_string(void);

/// gtk_widget_class_set_css_name etc. aren't needed; widgets get CSS classes. A GtkWidget's GObject pointer.
static inline GObject *herb_object(gpointer p) { return G_OBJECT(p); }

/// Pango attributes for a label: weight and size in points.
PangoAttrList *herb_attrs(int weight, double points);

/// AdwAlertDialog responses come back as a string id.
typedef void (*HerbResponse)(void *data, const char *response);
void herb_alert_choose(AdwAlertDialog *dialog, GtkWidget *parent, HerbResponse done, void *data);

/// GtkFileDialog: open (files and/or folders), select folder, save. Paths come back newline-separated, or NULL.
void herb_file_open(GtkWindow *parent, const char *title, const char *accept, const char *initial_folder,
                    gboolean folders, gboolean multiple, const char *pattern, HerbReceived done, void *data);
void herb_file_save(GtkWindow *parent, const char *title, const char *initial_folder, const char *name,
                    HerbReceived done, void *data);

/// Opens a file or URI with its default app, or shows it in the file manager.
void herb_launch_file(GtkWindow *parent, const char *path, gboolean reveal);
void herb_launch_uri(GtkWindow *parent, const char *uri);

/* Copies a picture of `widget` (a window, header bar included) to the clipboard. */
gboolean herb_copy_widget_image(GtkWidget *widget);

#endif
