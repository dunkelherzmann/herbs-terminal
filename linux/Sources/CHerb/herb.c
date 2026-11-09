#include "herb.h"
#include <glib-unix.h>
#include <math.h>
#include <string.h>
#include <unistd.h>

// MARK: Signals

typedef struct {
    GClosure closure;
    HerbCallback callback;
    void *data;
    HerbRelease release;
} HerbClosure;

static void herb_marshal(GClosure *closure, GValue *return_value, guint count, const GValue *values,
                         gpointer hint, gpointer marshal_data) {
    HerbClosure *self = (HerbClosure *)closure;
    self->callback(self->data, return_value, count, values);
}

static void herb_finalize(gpointer notify_data, GClosure *closure) {
    HerbClosure *self = (HerbClosure *)closure;
    if (self->release) self->release(self->data);
}

GClosure *herb_closure(HerbCallback callback, void *data, HerbRelease release) {
    GClosure *closure = g_closure_new_simple(sizeof(HerbClosure), NULL);
    HerbClosure *self = (HerbClosure *)closure;
    self->callback = callback;
    self->data = data;
    self->release = release;
    g_closure_set_marshal(closure, herb_marshal);
    g_closure_add_finalize_notifier(closure, NULL, herb_finalize);
    return closure;
}

gulong herb_connect(gpointer instance, const char *signal, HerbCallback callback, void *data, HerbRelease release,
                    gboolean after) {
    return g_signal_connect_closure(instance, signal, herb_closure(callback, data, release), after);
}

// MARK: libdispatch main queue in the GLib loop

extern int _dispatch_get_main_queue_handle_4CF(void);
extern void _dispatch_main_queue_callback_4CF(void *message);

static gboolean herb_dispatch_ready(gint fd, GIOCondition condition, gpointer user_data) {
    guint64 count;
    // Clears the wakeup; libdispatch's own descriptor is non-blocking.
    ssize_t ignored = read(fd, &count, sizeof count);
    (void)ignored;
    _dispatch_main_queue_callback_4CF(NULL);
    return G_SOURCE_CONTINUE;
}

static gboolean herb_dispatch_drain(gpointer user_data) {
    _dispatch_main_queue_callback_4CF(NULL);
    return G_SOURCE_CONTINUE;
}

void herb_integrate_dispatch(void) {
    int fd = _dispatch_get_main_queue_handle_4CF();
    if (fd >= 0) g_unix_fd_add(fd, G_IO_IN, herb_dispatch_ready, NULL);
    // A slow safety net for work queued before the descriptor existed.
    g_timeout_add(250, herb_dispatch_drain, NULL);
}

// MARK: Timeouts

typedef struct {
    gboolean (*callback)(void *);
    void *data;
    HerbRelease release;
} HerbSource;

static gboolean herb_source_fire(gpointer user_data) {
    HerbSource *source = user_data;
    return source->callback(source->data);
}

static void herb_source_free(gpointer user_data) {
    HerbSource *source = user_data;
    if (source->release) source->release(source->data);
    g_free(source);
}

guint herb_timeout(guint milliseconds, gboolean (*callback)(void *), void *data, HerbRelease release) {
    HerbSource *source = g_new0(HerbSource, 1);
    source->callback = callback;
    source->data = data;
    source->release = release;
    return g_timeout_add_full(G_PRIORITY_DEFAULT, milliseconds, herb_source_fire, source, herb_source_free);
}

guint herb_idle(gboolean (*callback)(void *), void *data, HerbRelease release) {
    HerbSource *source = g_new0(HerbSource, 1);
    source->callback = callback;
    source->data = data;
    source->release = release;
    return g_idle_add_full(G_PRIORITY_DEFAULT_IDLE, herb_source_fire, source, herb_source_free);
}

// MARK: Properties

void herb_set_bool(gpointer object, const char *name, gboolean value) { g_object_set(object, name, value, NULL); }
void herb_set_int(gpointer object, const char *name, gint value) { g_object_set(object, name, value, NULL); }
void herb_set_uint(gpointer object, const char *name, guint value) { g_object_set(object, name, value, NULL); }
void herb_set_double(gpointer object, const char *name, gdouble value) { g_object_set(object, name, value, NULL); }
void herb_set_string(gpointer object, const char *name, const char *value) { g_object_set(object, name, value, NULL); }
void herb_set_object(gpointer object, const char *name, gpointer value) { g_object_set(object, name, value, NULL); }

gboolean herb_get_bool(gpointer object, const char *name) {
    gboolean value = FALSE;
    g_object_get(object, name, &value, NULL);
    return value;
}

char *herb_get_string(gpointer object, const char *name) {
    char *value = NULL;
    g_object_get(object, name, &value, NULL);
    return value;
}

// MARK: VTE

typedef struct {
    HerbSpawned done;
    void *data;
} HerbSpawn;

static void herb_spawned(VteTerminal *terminal, GPid pid, GError *error, gpointer user_data) {
    HerbSpawn *spawn = user_data;
    spawn->done(spawn->data, error ? -1 : pid, error ? error->message : NULL);
    g_free(spawn);
}

void herb_vte_spawn(VteTerminal *terminal, const char *directory, char **argv, char **envv, gboolean host, HerbSpawned done,
                    void *data) {
    HerbSpawn *spawn = g_new0(HerbSpawn, 1);
    spawn->done = done;
    spawn->data = data;
    vte_terminal_spawn_async(terminal, host ? VTE_PTY_NO_CTTY : VTE_PTY_DEFAULT, directory, argv, envv, G_SPAWN_SEARCH_PATH, NULL, NULL, NULL,
                             -1, NULL, herb_spawned, spawn);
}

// Feature tests: answers an alert as if that button had been clicked.
void herb_alert_respond(AdwAlertDialog *dialog, const char *response) {
    g_signal_emit_by_name(dialog, "response", response);
    adw_dialog_force_close(ADW_DIALOG(dialog));
}

// MARK: Lazy file clipboard

#define HERB_TYPE_LAZY_PROVIDER (herb_lazy_provider_get_type())
G_DECLARE_FINAL_TYPE(HerbLazyProvider, herb_lazy_provider, HERB, LAZY_PROVIDER, GdkContentProvider)

struct _HerbLazyProvider {
    GdkContentProvider parent;
    HerbProvide provide;
    void *data;
    HerbRelease release;
};

G_DEFINE_TYPE(HerbLazyProvider, herb_lazy_provider, GDK_TYPE_CONTENT_PROVIDER)

static const char *herb_lazy_mimes[] = {"text/uri-list", "x-special/gnome-copied-files", "text/plain;charset=utf-8", NULL};

static GdkContentFormats *herb_lazy_ref_formats(GdkContentProvider *provider) {
    return gdk_content_formats_new(herb_lazy_mimes, 3);
}

static void herb_lazy_write(GdkContentProvider *provider, const char *mime_type, GOutputStream *stream, int priority,
                            GCancellable *cancellable, GAsyncReadyCallback callback, gpointer user_data) {
    HerbLazyProvider *self = HERB_LAZY_PROVIDER(provider);
    GTask *task = g_task_new(provider, cancellable, callback, user_data);
    char *text = self->provide ? self->provide(self->data, mime_type) : NULL;
    if (!text) {
        g_task_return_new_error(task, G_IO_ERROR, G_IO_ERROR_NOT_SUPPORTED, "The files couldn't be fetched.");
    } else {
        GError *error = NULL;
        gsize written = 0;
        if (g_output_stream_write_all(stream, text, strlen(text), &written, cancellable, &error)) {
            g_task_return_boolean(task, TRUE);
        } else {
            g_task_return_error(task, error);
        }
        g_free(text);
    }
    g_object_unref(task);
}

static gboolean herb_lazy_write_finish(GdkContentProvider *provider, GAsyncResult *result, GError **error) {
    return g_task_propagate_boolean(G_TASK(result), error);
}

static void herb_lazy_finalize(GObject *object) {
    HerbLazyProvider *self = HERB_LAZY_PROVIDER(object);
    if (self->release) self->release(self->data);
    G_OBJECT_CLASS(herb_lazy_provider_parent_class)->finalize(object);
}

static void herb_lazy_provider_class_init(HerbLazyProviderClass *klass) {
    GdkContentProviderClass *provider = GDK_CONTENT_PROVIDER_CLASS(klass);
    provider->ref_formats = herb_lazy_ref_formats;
    provider->write_mime_type_async = herb_lazy_write;
    provider->write_mime_type_finish = herb_lazy_write_finish;
    G_OBJECT_CLASS(klass)->finalize = herb_lazy_finalize;
}

static void herb_lazy_provider_init(HerbLazyProvider *self) {}

GdkContentProvider *herb_lazy_files_provider(HerbProvide provide, void *data, HerbRelease release) {
    HerbLazyProvider *self = g_object_new(HERB_TYPE_LAZY_PROVIDER, NULL);
    self->provide = provide;
    self->data = data;
    self->release = release;
    return GDK_CONTENT_PROVIDER(self);
}

// MARK: Clipboard reading

typedef struct {
    HerbReceived done;
    void *data;
} HerbRead;

static void herb_files_read(GObject *source, GAsyncResult *result, gpointer user_data) {
    HerbRead *read = user_data;
    const GValue *value = gdk_clipboard_read_value_finish(GDK_CLIPBOARD(source), result, NULL);
    char *paths = value ? herb_drop_paths(value) : NULL;
    read->done(read->data, paths);
    g_free(paths);
    g_free(read);
}

void herb_clipboard_read_files(GdkClipboard *clipboard, HerbReceived done, void *data) {
    HerbRead *read = g_new0(HerbRead, 1);
    read->done = done;
    read->data = data;
    gdk_clipboard_read_value_async(clipboard, GDK_TYPE_FILE_LIST, G_PRIORITY_DEFAULT, NULL, herb_files_read, read);
}

static void herb_text_read(GObject *source, GAsyncResult *result, gpointer user_data) {
    HerbRead *read = user_data;
    char *text = gdk_clipboard_read_text_finish(GDK_CLIPBOARD(source), result, NULL);
    read->done(read->data, text);
    g_free(text);
    g_free(read);
}

void herb_clipboard_read_text(GdkClipboard *clipboard, HerbReceived done, void *data) {
    HerbRead *read = g_new0(HerbRead, 1);
    read->done = done;
    read->data = data;
    gdk_clipboard_read_text_async(clipboard, NULL, herb_text_read, read);
}

void herb_clipboard_set_files(GdkClipboard *clipboard, const char *paths, gboolean cut) {
    char **lines = g_strsplit(paths, "\n", -1);
    GSList *files = NULL;
    GString *uris = g_string_new(NULL);
    GString *gnome = g_string_new(cut ? "cut" : "copy");
    for (char **line = lines; *line; line++) {
        if (!**line) continue;
        GFile *file = g_file_new_for_path(*line);
        files = g_slist_append(files, file);
        char *uri = g_file_get_uri(file);
        g_string_append_printf(uris, "%s\r\n", uri);
        g_string_append_printf(gnome, "\n%s", uri);
        g_free(uri);
    }
    GdkFileList *list = gdk_file_list_new_from_list(files);
    GValue value = G_VALUE_INIT;
    g_value_init(&value, GDK_TYPE_FILE_LIST);
    g_value_take_boxed(&value, list);
    GBytes *uri_bytes = g_bytes_new(uris->str, uris->len);
    GBytes *gnome_bytes = g_bytes_new(gnome->str, gnome->len);
    GdkContentProvider *providers[3] = {
        gdk_content_provider_new_for_value(&value),
        gdk_content_provider_new_for_bytes("text/uri-list", uri_bytes),
        gdk_content_provider_new_for_bytes("x-special/gnome-copied-files", gnome_bytes),
    };
    GdkContentProvider *union_provider = gdk_content_provider_new_union(providers, 3);
    gdk_clipboard_set_content(clipboard, union_provider);
    g_object_unref(union_provider);
    g_value_unset(&value);
    g_bytes_unref(uri_bytes);
    g_bytes_unref(gnome_bytes);
    g_slist_free_full(files, g_object_unref);
    g_string_free(uris, TRUE);
    g_string_free(gnome, TRUE);
    g_strfreev(lines);
}

gboolean herb_clipboard_has_files(GdkClipboard *clipboard) {
    GdkContentFormats *formats = gdk_clipboard_get_formats(clipboard);
    return gdk_content_formats_contain_gtype(formats, GDK_TYPE_FILE_LIST) ||
           gdk_content_formats_contain_mime_type(formats, "text/uri-list");
}

// MARK: Values

gpointer herb_value_pointer(const GValue *values, guint index) {
    const GValue *value = &values[index];
    if (G_VALUE_HOLDS_OBJECT(value)) return g_value_get_object(value);
    if (G_VALUE_HOLDS_POINTER(value)) return g_value_get_pointer(value);
    if (G_VALUE_HOLDS_BOXED(value)) return g_value_get_boxed(value);
    return NULL;
}
gint herb_value_int(const GValue *values, guint index) {
    const GValue *value = &values[index];
    if (G_VALUE_HOLDS_INT(value)) return g_value_get_int(value);
    if (G_VALUE_HOLDS_UINT(value)) return (gint)g_value_get_uint(value);
    if (G_VALUE_HOLDS_ENUM(value)) return g_value_get_enum(value);
    if (G_VALUE_HOLDS_FLAGS(value)) return (gint)g_value_get_flags(value);
    return 0;
}
guint herb_value_uint(const GValue *values, guint index) {
    const GValue *value = &values[index];
    if (G_VALUE_HOLDS_UINT(value)) return g_value_get_uint(value);
    if (G_VALUE_HOLDS_INT(value)) return (guint)g_value_get_int(value);
    if (G_VALUE_HOLDS_FLAGS(value)) return g_value_get_flags(value);
    if (G_VALUE_HOLDS_ENUM(value)) return (guint)g_value_get_enum(value);
    return 0;
}
gdouble herb_value_double(const GValue *values, guint index) {
    const GValue *value = &values[index];
    if (G_VALUE_HOLDS_DOUBLE(value)) return g_value_get_double(value);
    if (G_VALUE_HOLDS_FLOAT(value)) return g_value_get_float(value);
    return 0;
}
const char *herb_value_string(const GValue *values, guint index) {
    const GValue *value = &values[index];
    return G_VALUE_HOLDS_STRING(value) ? g_value_get_string(value) : NULL;
}
gboolean herb_value_bool(const GValue *values, guint index) {
    const GValue *value = &values[index];
    return G_VALUE_HOLDS_BOOLEAN(value) ? g_value_get_boolean(value) : FALSE;
}
void herb_return_bool(GValue *value, gboolean result) {
    if (value && G_VALUE_HOLDS_BOOLEAN(value)) g_value_set_boolean(value, result);
}

void herb_return_pointer(GValue *value, gpointer object) {
    if (value && G_VALUE_HOLDS_OBJECT(value)) g_value_take_object(value, object);
    else if (object) g_object_unref(object);
}

char *herb_drop_paths(const GValue *value) {
    if (!G_VALUE_HOLDS(value, GDK_TYPE_FILE_LIST)) {
        if (G_VALUE_HOLDS_STRING(value)) return g_strdup(g_value_get_string(value));
        return NULL;
    }
    GSList *files = gdk_file_list_get_files(g_value_get_boxed(value));
    GString *text = g_string_new(NULL);
    for (GSList *item = files; item; item = item->next) {
        char *path = g_file_get_path(item->data);
        if (path) {
            if (text->len) g_string_append_c(text, '\n');
            g_string_append(text, path);
            g_free(path);
        }
    }
    g_slist_free(files);
    return g_string_free(text, FALSE);
}

typedef struct {
    HerbReceived done;
    void *data;
    GdkDrop *drop;
    GOutputStream *out;
} HerbDropRead;

static void herb_drop_done(HerbDropRead *read, char *paths) {
    if (paths && !*paths) g_clear_pointer(&paths, g_free);
    gdk_drop_finish(read->drop, paths ? GDK_ACTION_COPY : 0);
    read->done(read->data, paths);
    g_free(paths);
    g_object_unref(read->drop);
    g_clear_object(&read->out);
    g_free(read);
}

/// file:// URIs as paths; anything else (smb://, http://) has no local path and is left out.
static char *herb_uri_list_paths(const char *text) {
    char **uris = g_uri_list_extract_uris(text);
    GString *paths = g_string_new(NULL);
    for (char **uri = uris; uri && *uri; uri++) {
        char *path = g_filename_from_uri(*uri, NULL, NULL);
        if (path) {
            if (paths->len) g_string_append_c(paths, '\n');
            g_string_append(paths, path);
            g_free(path);
        }
    }
    g_strfreev(uris);
    return g_string_free(paths, FALSE);
}

static void herb_drop_spliced(GObject *source, GAsyncResult *result, gpointer user_data) {
    HerbDropRead *read = user_data;
    char *paths = NULL;
    if (g_output_stream_splice_finish(G_OUTPUT_STREAM(source), result, NULL) >= 0) {
        GMemoryOutputStream *memory = G_MEMORY_OUTPUT_STREAM(read->out);
        char *text = g_strndup(g_memory_output_stream_get_data(memory), g_memory_output_stream_get_data_size(memory));
        paths = herb_uri_list_paths(text);
        g_free(text);
    }
    herb_drop_done(read, paths);
}

static void herb_drop_stream(GObject *source, GAsyncResult *result, gpointer user_data) {
    HerbDropRead *read = user_data;
    GInputStream *input = gdk_drop_read_finish(GDK_DROP(source), result, NULL, NULL);
    if (!input) { herb_drop_done(read, NULL); return; }
    read->out = g_memory_output_stream_new_resizable();
    g_output_stream_splice_async(read->out, input,
                                 G_OUTPUT_STREAM_SPLICE_CLOSE_SOURCE | G_OUTPUT_STREAM_SPLICE_CLOSE_TARGET,
                                 G_PRIORITY_DEFAULT, NULL, herb_drop_spliced, read);
    g_object_unref(input);
}

static void herb_drop_value(GObject *source, GAsyncResult *result, gpointer user_data) {
    HerbDropRead *read = user_data;
    const GValue *value = gdk_drop_read_value_finish(GDK_DROP(source), result, NULL);
    herb_drop_done(read, value ? herb_drop_paths(value) : NULL);
}

static gboolean herb_files_accept(GtkDropTargetAsync *target, GdkDrop *drop, gpointer user_data) {
    GdkContentFormats *formats = gdk_drop_get_formats(drop);
    return gdk_content_formats_contain_mime_type(formats, "text/uri-list")
        || gdk_content_formats_contain_gtype(formats, GDK_TYPE_FILE_LIST);
}

/// Every hover is answered with a copy, which is what a drop here means. Without these answers a drag from
/// Dolphin (KDE on Wayland) never reached the "drop" handler.
static GdkDragAction herb_files_hover(GtkDropTargetAsync *target, GdkDrop *drop, double x, double y, gpointer user_data) {
    return GDK_ACTION_COPY;
}

/// The drop target for files from a file manager. Keep it a GtkDropTargetAsync that answers "drag-enter" and
/// "drag-motion" with a copy and reads text/uri-list itself: a plain GtkDropTarget for GdkFileList silently
/// receives no drop from Dolphin. To see what a drag delivers, log "accept", "drag-enter" and "drop" with
/// g_message and read the user journal (journalctl --user -f).
GtkEventController *herb_files_drop_target(void) {
    GdkContentFormatsBuilder *builder = gdk_content_formats_builder_new();
    gdk_content_formats_builder_add_mime_type(builder, "text/uri-list");
    gdk_content_formats_builder_add_gtype(builder, GDK_TYPE_FILE_LIST);
    GtkDropTargetAsync *target = gtk_drop_target_async_new(gdk_content_formats_builder_free_to_formats(builder), GDK_ACTION_COPY);
    g_signal_connect(target, "accept", G_CALLBACK(herb_files_accept), NULL);
    g_signal_connect(target, "drag-enter", G_CALLBACK(herb_files_hover), NULL);
    g_signal_connect(target, "drag-motion", G_CALLBACK(herb_files_hover), NULL);
    return GTK_EVENT_CONTROLLER(target);
}

void herb_drop_read_paths(const GValue *value, HerbReceived done, void *data) {
    HerbDropRead *read = g_new0(HerbDropRead, 1);
    read->done = done;
    read->data = data;
    read->drop = g_object_ref(GDK_DROP(g_value_get_object(value)));
    if (gdk_content_formats_contain_mime_type(gdk_drop_get_formats(read->drop), "text/uri-list")) {
        static const char *mime_types[] = { "text/uri-list", NULL };
        gdk_drop_read_async(read->drop, mime_types, G_PRIORITY_DEFAULT, NULL, herb_drop_stream, read);
    } else {
        gdk_drop_read_value_async(read->drop, GDK_TYPE_FILE_LIST, G_PRIORITY_DEFAULT, NULL, herb_drop_value, read);
    }
}

GType herb_type_file_list(void) { return GDK_TYPE_FILE_LIST; }
GType herb_type_string(void) { return G_TYPE_STRING; }
GType herb_type_int(void) { return G_TYPE_INT; }
GType herb_type_boolean(void) { return G_TYPE_BOOLEAN; }

PangoAttrList *herb_attrs(int weight, double points) {
    PangoAttrList *list = pango_attr_list_new();
    if (weight > 0) pango_attr_list_insert(list, pango_attr_weight_new(weight));
    if (points > 0) pango_attr_list_insert(list, pango_attr_size_new((int)(points * PANGO_SCALE)));
    return list;
}

// MARK: Dialogs

typedef struct {
    HerbResponse done;
    void *data;
} HerbChoose;

static void herb_alert_chosen(GObject *source, GAsyncResult *result, gpointer user_data) {
    HerbChoose *choose = user_data;
    const char *response = adw_alert_dialog_choose_finish(ADW_ALERT_DIALOG(source), result);
    choose->done(choose->data, response);
    g_free(choose);
}

void herb_alert_choose(AdwAlertDialog *dialog, GtkWidget *parent, HerbResponse done, void *data) {
    HerbChoose *choose = g_new0(HerbChoose, 1);
    choose->done = done;
    choose->data = data;
    adw_alert_dialog_choose(dialog, parent, NULL, herb_alert_chosen, choose);
}

typedef struct {
    HerbReceived done;
    void *data;
    int kind;  // 0 open one file, 1 open many, 2 folder, 3 folders, 4 save
} HerbPick;

static char *herb_join_files(GListModel *files) {
    GString *text = g_string_new(NULL);
    guint count = g_list_model_get_n_items(files);
    for (guint i = 0; i < count; i++) {
        GFile *file = g_list_model_get_item(files, i);
        char *path = g_file_get_path(file);
        if (path) {
            if (text->len) g_string_append_c(text, '\n');
            g_string_append(text, path);
            g_free(path);
        }
        g_object_unref(file);
    }
    return g_string_free(text, FALSE);
}

static void herb_file_picked(GObject *source, GAsyncResult *result, gpointer user_data) {
    HerbPick *pick = user_data;
    GtkFileDialog *dialog = GTK_FILE_DIALOG(source);
    char *paths = NULL;
    GFile *file = NULL;
    GListModel *files = NULL;
    switch (pick->kind) {
    case 0: file = gtk_file_dialog_open_finish(dialog, result, NULL); break;
    case 1: files = gtk_file_dialog_open_multiple_finish(dialog, result, NULL); break;
    case 2: file = gtk_file_dialog_select_folder_finish(dialog, result, NULL); break;
    case 3: files = gtk_file_dialog_select_multiple_folders_finish(dialog, result, NULL); break;
    case 4: file = gtk_file_dialog_save_finish(dialog, result, NULL); break;
    }
    if (file) { paths = g_file_get_path(file); g_object_unref(file); }
    if (files) { paths = herb_join_files(files); g_object_unref(files); }
    pick->done(pick->data, paths);
    g_free(paths);
    g_free(pick);
}

void herb_file_open(GtkWindow *parent, const char *title, const char *accept, const char *initial_folder,
                    gboolean folders, gboolean multiple, const char *pattern, HerbReceived done, void *data) {
    GtkFileDialog *dialog = gtk_file_dialog_new();
    gtk_file_dialog_set_title(dialog, title);
    if (accept) gtk_file_dialog_set_accept_label(dialog, accept);
    if (initial_folder) {
        GFile *folder = g_file_new_for_path(initial_folder);
        gtk_file_dialog_set_initial_folder(dialog, folder);
        g_object_unref(folder);
    }
    if (pattern) {
        GtkFileFilter *filter = gtk_file_filter_new();
        gtk_file_filter_add_pattern(filter, pattern);
        gtk_file_filter_set_name(filter, pattern);
        GListStore *filters = g_list_store_new(GTK_TYPE_FILE_FILTER);
        g_list_store_append(filters, filter);
        gtk_file_dialog_set_filters(dialog, G_LIST_MODEL(filters));
        g_object_unref(filters);
        g_object_unref(filter);
    }
    HerbPick *pick = g_new0(HerbPick, 1);
    pick->done = done;
    pick->data = data;
    pick->kind = folders ? (multiple ? 3 : 2) : (multiple ? 1 : 0);
    switch (pick->kind) {
    case 0: gtk_file_dialog_open(dialog, parent, NULL, herb_file_picked, pick); break;
    case 1: gtk_file_dialog_open_multiple(dialog, parent, NULL, herb_file_picked, pick); break;
    case 2: gtk_file_dialog_select_folder(dialog, parent, NULL, herb_file_picked, pick); break;
    case 3: gtk_file_dialog_select_multiple_folders(dialog, parent, NULL, herb_file_picked, pick); break;
    }
    g_object_unref(dialog);
}

void herb_file_save(GtkWindow *parent, const char *title, const char *initial_folder, const char *name,
                    HerbReceived done, void *data) {
    GtkFileDialog *dialog = gtk_file_dialog_new();
    gtk_file_dialog_set_title(dialog, title);
    if (initial_folder) {
        GFile *folder = g_file_new_for_path(initial_folder);
        gtk_file_dialog_set_initial_folder(dialog, folder);
        g_object_unref(folder);
    }
    if (name) gtk_file_dialog_set_initial_name(dialog, name);
    HerbPick *pick = g_new0(HerbPick, 1);
    pick->done = done;
    pick->data = data;
    pick->kind = 4;
    gtk_file_dialog_save(dialog, parent, NULL, herb_file_picked, pick);
    g_object_unref(dialog);
}

void herb_launch_file(GtkWindow *parent, const char *path, gboolean reveal) {
    GFile *file = g_file_new_for_path(path);
    GtkFileLauncher *launcher = gtk_file_launcher_new(file);
    if (reveal) gtk_file_launcher_open_containing_folder(launcher, parent, NULL, NULL, NULL);
    else gtk_file_launcher_launch(launcher, parent, NULL, NULL, NULL);
    g_object_unref(launcher);
    g_object_unref(file);
}

void herb_launch_uri(GtkWindow *parent, const char *uri) {
    GtkUriLauncher *launcher = gtk_uri_launcher_new(uri);
    gtk_uri_launcher_launch(launcher, parent, NULL, NULL, NULL);
    g_object_unref(launcher);
}

/* Take Screenshot: a window (header bar included) drawn at the screen's scale, onto the clipboard as an image.
   FALSE when there is nothing to draw. The window's background is drawn, then its content (the header bar and
   everything below it) as its parent draws it: a widget paintable comes back empty after its first picture. */
static GdkTexture *herb_widget_texture(GtkWidget *widget) {
    GtkWidget *target = widget;
    if (ADW_IS_APPLICATION_WINDOW(widget)) target = adw_application_window_get_content(ADW_APPLICATION_WINDOW(widget));
    else if (ADW_IS_WINDOW(widget)) target = adw_window_get_content(ADW_WINDOW(widget));
    GtkWidget *parent = target ? gtk_widget_get_parent(target) : NULL;
    GtkNative *native = gtk_widget_get_native(widget);
    graphene_rect_t area;
    if (parent == NULL || native == NULL || !gtk_widget_get_mapped(target)
        || !gtk_widget_compute_bounds(target, parent, &area) || area.size.width < 1 || area.size.height < 1) return NULL;
    float scale = (float)gdk_surface_get_scale(gtk_native_get_surface(native));
    GtkSnapshot *snapshot = gtk_snapshot_new();
    gtk_snapshot_scale(snapshot, scale, scale);
    /* The window's own background first: bars that are partly see-through (the explorer's location bar, the
       MultiExec bar) are drawn over it, as on screen. */
    G_GNUC_BEGIN_IGNORE_DEPRECATIONS
    gtk_snapshot_render_background(snapshot, gtk_widget_get_style_context(widget), 0, 0, area.size.width, area.size.height);
    G_GNUC_END_IGNORE_DEPRECATIONS
    gtk_snapshot_translate(snapshot, &GRAPHENE_POINT_INIT(-area.origin.x, -area.origin.y));
    gtk_widget_snapshot_child(parent, target, snapshot);
    GskRenderNode *node = gtk_snapshot_free_to_node(snapshot);
    if (node == NULL) return NULL;
    graphene_rect_t bounds = GRAPHENE_RECT_INIT(0, 0, ceilf(area.size.width * scale), ceilf(area.size.height * scale));
    GdkTexture *texture = gsk_renderer_render_texture(gtk_native_get_renderer(native), node, &bounds);
    if (texture == NULL) {
        /* Some backends (Broadway) can't render to a texture; GTK's software renderer always can. */
        GskRenderer *software = gsk_cairo_renderer_new();
        if (gsk_renderer_realize_for_display(software, gtk_widget_get_display(widget), NULL)) {
            texture = gsk_renderer_render_texture(software, node, &bounds);
            gsk_renderer_unrealize(software);
        }
        g_object_unref(software);
    }
    gsk_render_node_unref(node);
    return texture;
}

gboolean herb_copy_widget_image(GtkWidget *widget) {
    GdkTexture *texture = herb_widget_texture(widget);
    if (texture == NULL) return FALSE;
    gdk_clipboard_set_texture(gtk_widget_get_clipboard(widget), texture);
    g_object_unref(texture);
    return TRUE;
}

/* A widget's bounds in its window's coordinates (parity checks): x, y, width, height. FALSE when not shown. */
gboolean herb_widget_bounds(GtkWidget *widget, double *out) {
    GtkRoot *root = gtk_widget_get_root(widget);
    graphene_rect_t bounds;
    if (root == NULL || !gtk_widget_get_mapped(widget) || !gtk_widget_compute_bounds(widget, GTK_WIDGET(root), &bounds)) return FALSE;
    out[0] = bounds.origin.x; out[1] = bounds.origin.y; out[2] = bounds.size.width; out[3] = bounds.size.height;
    return TRUE;
}

/* The same picture as Take Screenshot, saved as a PNG file (parity checks). */
gboolean herb_save_widget_image(GtkWidget *widget, const char *path) {
    GdkTexture *texture = herb_widget_texture(widget);
    if (texture == NULL) return FALSE;
    gboolean saved = gdk_texture_save_to_png(texture, path);
    g_object_unref(texture);
    return saved;
}
