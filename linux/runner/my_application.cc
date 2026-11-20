#include "my_application.h"

#include <dlfcn.h>
#include <flutter_linux/flutter_linux.h>
#include <unistd.h>

#include <cstdint>
#include <string>
#include <vector>

#include "flutter/generated_plugin_registrant.h"

namespace {

constexpr int kIndicatorCategoryApplicationStatus = 0;
constexpr int kIndicatorStatusActive = 1;

typedef void* (*FnAppIndicatorNew)(const gchar* id,
                                   const gchar* icon_name,
                                   int category);
typedef void (*FnAppIndicatorSetStatus)(void* indicator, int status);
typedef void (*FnAppIndicatorSetMenu)(void* indicator, GtkMenu* menu);
typedef void (*FnAppIndicatorSetIconFull)(void* indicator,
                                          const gchar* icon_name,
                                          const gchar* icon_desc);
typedef void (*FnAppIndicatorSetTitle)(void* indicator, const gchar* title);

struct IndicatorApi {
  void* handle = nullptr;
  FnAppIndicatorNew new_fn = nullptr;
  FnAppIndicatorSetStatus set_status_fn = nullptr;
  FnAppIndicatorSetMenu set_menu_fn = nullptr;
  FnAppIndicatorSetIconFull set_icon_full_fn = nullptr;
  FnAppIndicatorSetTitle set_title_fn = nullptr;

  bool Load() {
    if (handle != nullptr) return new_fn != nullptr;
    const char* libs[] = {
        "libayatana-appindicator3.so.1",
        "libappindicator3.so.1",
    };
    for (const char* lib : libs) {
      handle = dlopen(lib, RTLD_LAZY);
      if (handle != nullptr) {
        new_fn = reinterpret_cast<FnAppIndicatorNew>(
            dlsym(handle, "app_indicator_new"));
        set_status_fn = reinterpret_cast<FnAppIndicatorSetStatus>(
            dlsym(handle, "app_indicator_set_status"));
        set_menu_fn = reinterpret_cast<FnAppIndicatorSetMenu>(
            dlsym(handle, "app_indicator_set_menu"));
        set_icon_full_fn = reinterpret_cast<FnAppIndicatorSetIconFull>(
            dlsym(handle, "app_indicator_set_icon_full"));
        set_title_fn = reinterpret_cast<FnAppIndicatorSetTitle>(
            dlsym(handle, "app_indicator_set_title"));
        if (new_fn && set_status_fn && set_menu_fn) {
          return true;
        }
        dlclose(handle);
        handle = nullptr;
      }
    }
    return false;
  }
};

std::string ResolveTrayIconPath() {
  char exe_buf[4096] = {};
  ssize_t n = readlink("/proc/self/exe", exe_buf, sizeof(exe_buf) - 1);
  if (n > 0) {
    exe_buf[n] = '\0';
    g_autofree gchar* dir = g_path_get_dirname(exe_buf);
    g_autofree gchar* candidate = g_build_filename(
        dir, "data", "flutter_assets", "assets", "images", "icon.png", nullptr);
    if (g_file_test(candidate, G_FILE_TEST_EXISTS)) {
      return std::string(candidate);
    }
  }
  return "folder-remote";
}

const gchar* LookupString(FlValue* map, const char* key, const gchar* def) {
  if (!map || fl_value_get_type(map) != FL_VALUE_TYPE_MAP) return def;
  FlValue* v = fl_value_lookup_string(map, key);
  if (v && fl_value_get_type(v) == FL_VALUE_TYPE_STRING) {
    return fl_value_get_string(v);
  }
  return def;
}

bool LookupBool(FlValue* map, const char* key, bool def) {
  if (!map || fl_value_get_type(map) != FL_VALUE_TYPE_MAP) return def;
  FlValue* v = fl_value_lookup_string(map, key);
  if (v && fl_value_get_type(v) == FL_VALUE_TYPE_BOOL) {
    return fl_value_get_bool(v);
  }
  return def;
}

}  // namespace

struct _MyApplication {
  GtkApplication parent_instance;
  char** dart_entrypoint_arguments;
  GtkWindow* main_window;
  FlMethodChannel* desktop_channel;
  IndicatorApi indicator_api;
  void* tray_indicator;
  GtkWidget* tray_menu;
  GtkWidget* item_open;
  GtkWidget* item_send;
  GtkWidget* item_downloads;
  GtkWidget* item_auto_accept;
  GtkWidget* item_sounds;
  GtkWidget* item_exit;
  bool minimize_to_tray;
  bool auto_accept;
  bool sounds_enabled;
  bool suppress_toggle_signal;
  bool quitting;
};

G_DEFINE_TYPE(MyApplication, my_application, GTK_TYPE_APPLICATION)

static void emit_tray_action(MyApplication* self, const char* action) {
  if (!self->desktop_channel) return;
  g_autoptr(FlValue) arg = fl_value_new_string(action);
  fl_method_channel_invoke_method(self->desktop_channel, "onTrayAction", arg,
                                  nullptr, nullptr, nullptr);
}

static void on_tray_open(GtkMenuItem* item, gpointer user_data) {
  (void)item;
  auto* self = MY_APPLICATION(user_data);
  if (self->main_window) {
    gtk_widget_show(GTK_WIDGET(self->main_window));
    gtk_window_present(self->main_window);
  }
  emit_tray_action(self, "open");
}

static void on_tray_send(GtkMenuItem* item, gpointer user_data) {
  (void)item;
  auto* self = MY_APPLICATION(user_data);
  if (self->main_window) {
    gtk_widget_show(GTK_WIDGET(self->main_window));
    gtk_window_present(self->main_window);
  }
  emit_tray_action(self, "send");
}

static void on_tray_downloads(GtkMenuItem* item, gpointer user_data) {
  (void)item;
  emit_tray_action(MY_APPLICATION(user_data), "downloads");
}

static void on_tray_auto_accept(GtkCheckMenuItem* item, gpointer user_data) {
  (void)item;
  auto* self = MY_APPLICATION(user_data);
  if (self->suppress_toggle_signal) return;
  emit_tray_action(self, "toggleAutoAccept");
}

static void on_tray_sounds(GtkCheckMenuItem* item, gpointer user_data) {
  (void)item;
  auto* self = MY_APPLICATION(user_data);
  if (self->suppress_toggle_signal) return;
  emit_tray_action(self, "toggleSounds");
}

static void on_tray_exit(GtkMenuItem* item, gpointer user_data) {
  (void)item;
  auto* self = MY_APPLICATION(user_data);
  self->quitting = true;
  emit_tray_action(self, "exit");
  g_application_quit(G_APPLICATION(self));
}

static void init_or_update_tray(MyApplication* self, FlValue* args) {
  const gchar* open_lbl = LookupString(args, "open", "Open MaterialDrop");
  const gchar* send_lbl = LookupString(args, "send", "Send Files...");
  const gchar* dl_lbl = LookupString(args, "downloads", "Open Downloads");
  const gchar* auto_lbl = LookupString(args, "autoAccept", "Auto-accept");
  const gchar* snd_lbl = LookupString(args, "sounds", "Sounds");
  const gchar* exit_lbl = LookupString(args, "exit", "Exit");
  const gchar* tooltip = LookupString(args, "tooltip", "MaterialDrop");
  self->auto_accept = LookupBool(args, "autoAccept", self->auto_accept);
  self->sounds_enabled = LookupBool(args, "sounds", self->sounds_enabled);
  self->minimize_to_tray = LookupBool(args, "minimizeToTray", true);

  if (!self->tray_indicator && self->indicator_api.Load()) {
    std::string icon_path = ResolveTrayIconPath();
    self->tray_indicator = self->indicator_api.new_fn(
        "materialdrop-tray", icon_path.c_str(),
        kIndicatorCategoryApplicationStatus);
    if (self->tray_indicator) {
      self->tray_menu = gtk_menu_new();
      self->item_open = gtk_menu_item_new_with_label(open_lbl);
      self->item_send = gtk_menu_item_new_with_label(send_lbl);
      self->item_downloads = gtk_menu_item_new_with_label(dl_lbl);
      self->item_auto_accept =
          gtk_check_menu_item_new_with_label(auto_lbl);
      self->item_sounds = gtk_check_menu_item_new_with_label(snd_lbl);
      self->item_exit = gtk_menu_item_new_with_label(exit_lbl);

      g_signal_connect(self->item_open, "activate",
                       G_CALLBACK(on_tray_open), self);
      g_signal_connect(self->item_send, "activate",
                       G_CALLBACK(on_tray_send), self);
      g_signal_connect(self->item_downloads, "activate",
                       G_CALLBACK(on_tray_downloads), self);
      g_signal_connect(self->item_auto_accept, "toggled",
                       G_CALLBACK(on_tray_auto_accept), self);
      g_signal_connect(self->item_sounds, "toggled",
                       G_CALLBACK(on_tray_sounds), self);
      g_signal_connect(self->item_exit, "activate",
                       G_CALLBACK(on_tray_exit), self);

      gtk_menu_shell_append(GTK_MENU_SHELL(self->tray_menu), self->item_open);
      gtk_menu_shell_append(GTK_MENU_SHELL(self->tray_menu),
                            gtk_separator_menu_item_new());
      gtk_menu_shell_append(GTK_MENU_SHELL(self->tray_menu), self->item_send);
      gtk_menu_shell_append(GTK_MENU_SHELL(self->tray_menu),
                            self->item_downloads);
      gtk_menu_shell_append(GTK_MENU_SHELL(self->tray_menu),
                            gtk_separator_menu_item_new());
      gtk_menu_shell_append(GTK_MENU_SHELL(self->tray_menu),
                            self->item_auto_accept);
      gtk_menu_shell_append(GTK_MENU_SHELL(self->tray_menu),
                            self->item_sounds);
      gtk_menu_shell_append(GTK_MENU_SHELL(self->tray_menu),
                            gtk_separator_menu_item_new());
      gtk_menu_shell_append(GTK_MENU_SHELL(self->tray_menu), self->item_exit);

      gtk_widget_show_all(self->tray_menu);
      self->indicator_api.set_status_fn(self->tray_indicator,
                                        kIndicatorStatusActive);
      self->indicator_api.set_menu_fn(self->tray_indicator,
                                      GTK_MENU(self->tray_menu));
      if (self->indicator_api.set_icon_full_fn) {
        self->indicator_api.set_icon_full_fn(
            self->tray_indicator, icon_path.c_str(), "MaterialDrop");
      }
    }
  }

  if (self->tray_indicator && self->tray_menu) {
    gtk_menu_item_set_label(GTK_MENU_ITEM(self->item_open), open_lbl);
    gtk_menu_item_set_label(GTK_MENU_ITEM(self->item_send), send_lbl);
    gtk_menu_item_set_label(GTK_MENU_ITEM(self->item_downloads), dl_lbl);
    gtk_menu_item_set_label(GTK_MENU_ITEM(self->item_auto_accept), auto_lbl);
    gtk_menu_item_set_label(GTK_MENU_ITEM(self->item_sounds), snd_lbl);
    gtk_menu_item_set_label(GTK_MENU_ITEM(self->item_exit), exit_lbl);
    if (self->indicator_api.set_title_fn) {
      self->indicator_api.set_title_fn(self->tray_indicator, tooltip);
    }
    self->suppress_toggle_signal = true;
    gtk_check_menu_item_set_active(
        GTK_CHECK_MENU_ITEM(self->item_auto_accept), self->auto_accept);
    gtk_check_menu_item_set_active(
        GTK_CHECK_MENU_ITEM(self->item_sounds), self->sounds_enabled);
    self->suppress_toggle_signal = false;
  }
}

static FlValue* read_gtk_clipboard(const gchar* temp_dir) {
  FlValue* result = fl_value_new_map();
  GtkClipboard* cb = gtk_clipboard_get(GDK_SELECTION_CLIPBOARD);
  if (!cb) {
    fl_value_set_string_take(result, "type", fl_value_new_string("empty"));
    return result;
  }

  gchar** uris = gtk_clipboard_wait_for_uris(cb);
  if (uris) {
    FlValue* list = fl_value_new_list();
    for (int i = 0; uris[i] != nullptr; ++i) {
      g_autofree gchar* local_path =
          g_filename_from_uri(uris[i], nullptr, nullptr);
      if (local_path && g_file_test(local_path, G_FILE_TEST_EXISTS)) {
        fl_value_append_take(list, fl_value_new_string(local_path));
      }
    }
    g_strfreev(uris);
    if (fl_value_get_length(list) > 0) {
      fl_value_set_string_take(result, "type", fl_value_new_string("files"));
      fl_value_set_string_take(result, "paths", list);
      return result;
    }
    fl_value_unref(list);
  }

  GdkPixbuf* pix = gtk_clipboard_wait_for_image(cb);
  if (pix) {
    if (temp_dir && temp_dir[0] != '\0') {
      g_autofree gchar* name = g_strdup_printf(
          "clipboard_%lld.png", static_cast<long long>(g_get_monotonic_time()));
      g_autofree gchar* out_path = g_build_filename(temp_dir, name, nullptr);
      g_autoptr(GError) err = nullptr;
      if (gdk_pixbuf_save(pix, out_path, "png", &err, nullptr)) {
        g_object_unref(pix);
        fl_value_set_string_take(result, "type",
                                 fl_value_new_string("imageFile"));
        fl_value_set_string_take(result, "path", fl_value_new_string(out_path));
        return result;
      }
    }
    g_object_unref(pix);
  }

  g_autofree gchar* text = gtk_clipboard_wait_for_text(cb);
  if (text && text[0] != '\0') {
    fl_value_set_string_take(result, "type", fl_value_new_string("text"));
    fl_value_set_string_take(result, "text", fl_value_new_string(text));
    return result;
  }

  fl_value_set_string_take(result, "type", fl_value_new_string("empty"));
  return result;
}

static void desktop_method_call_handler(FlMethodChannel* channel,
                                        FlMethodCall* method_call,
                                        gpointer user_data) {
  (void)channel;
  auto* self = MY_APPLICATION(user_data);
  const gchar* method = fl_method_call_get_name(method_call);
  FlValue* args = fl_method_call_get_args(method_call);
  g_autoptr(FlMethodResponse) response = nullptr;

  if (g_strcmp0(method, "initTray") == 0) {
    init_or_update_tray(self, args);
    if (LookupBool(args, "startHidden", false) && self->main_window &&
        self->tray_indicator) {
      gtk_widget_hide(GTK_WIDGET(self->main_window));
    }
    response = FL_METHOD_RESPONSE(
        fl_method_success_response_new(fl_value_new_bool(true)));
  } else if (g_strcmp0(method, "updateTrayState") == 0) {
    init_or_update_tray(self, args);
    response = FL_METHOD_RESPONSE(
        fl_method_success_response_new(fl_value_new_bool(true)));
  } else if (g_strcmp0(method, "showWindow") == 0) {
    if (self->main_window) {
      gtk_widget_show(GTK_WIDGET(self->main_window));
      gtk_window_present(self->main_window);
    }
    response = FL_METHOD_RESPONSE(
        fl_method_success_response_new(fl_value_new_bool(true)));
  } else if (g_strcmp0(method, "hideWindow") == 0) {
    if (self->main_window) {
      gtk_widget_hide(GTK_WIDGET(self->main_window));
    }
    response = FL_METHOD_RESPONSE(
        fl_method_success_response_new(fl_value_new_bool(true)));
  } else if (g_strcmp0(method, "setWindowTitle") == 0) {
    if (self->main_window) {
      gtk_window_set_title(self->main_window,
                           LookupString(args, "title", "MaterialDrop"));
    }
    response = FL_METHOD_RESPONSE(
        fl_method_success_response_new(fl_value_new_bool(true)));
  } else if (g_strcmp0(method, "isWindowVisible") == 0) {
    gboolean vis = self->main_window &&
                   gtk_widget_get_visible(GTK_WIDGET(self->main_window));
    response = FL_METHOD_RESPONSE(
        fl_method_success_response_new(fl_value_new_bool(vis)));
  } else if (g_strcmp0(method, "isFullscreenGameRunning") == 0) {
    response = FL_METHOD_RESPONSE(
        fl_method_success_response_new(fl_value_new_bool(false)));
  } else if (g_strcmp0(method, "showNotification") == 0) {
    const gchar* title = LookupString(args, "title", "MaterialDrop");
    const gchar* body = LookupString(args, "body", "");
    g_autoptr(GNotification) notif = g_notification_new(title);
    g_notification_set_body(notif, body);
    g_application_send_notification(G_APPLICATION(self), "materialdrop-transfer",
                                    notif);
    response = FL_METHOD_RESPONSE(
        fl_method_success_response_new(fl_value_new_bool(true)));
  } else if (g_strcmp0(method, "readClipboard") == 0) {
    const gchar* temp_dir = LookupString(args, "tempDir", "");
    g_autoptr(FlValue) val = read_gtk_clipboard(temp_dir);
    response = FL_METHOD_RESPONSE(fl_method_success_response_new(val));
  } else if (g_strcmp0(method, "writeImageToClipboard") == 0) {
    const gchar* path = LookupString(args, "path", "");
    bool ok = false;
    if (path && path[0] != '\0') {
      g_autoptr(GError) err = nullptr;
      GdkPixbuf* pix = gdk_pixbuf_new_from_file(path, &err);
      if (pix) {
        GtkClipboard* cb = gtk_clipboard_get(GDK_SELECTION_CLIPBOARD);
        if (cb) {
          gtk_clipboard_set_image(cb, pix);
          ok = true;
        }
        g_object_unref(pix);
      }
    }
    response = FL_METHOD_RESPONSE(
        fl_method_success_response_new(fl_value_new_bool(ok)));
  } else if (g_strcmp0(method, "quitApp") == 0) {
    self->quitting = true;
    response = FL_METHOD_RESPONSE(
        fl_method_success_response_new(fl_value_new_bool(true)));
    fl_method_call_respond(method_call, response, nullptr);
    g_application_quit(G_APPLICATION(self));
    return;
  } else {
    response = FL_METHOD_RESPONSE(fl_method_not_implemented_response_new());
  }

  fl_method_call_respond(method_call, response, nullptr);
}

static gboolean on_window_delete_event(GtkWidget* widget, GdkEvent* event,
                                       gpointer user_data) {
  (void)event;
  auto* self = MY_APPLICATION(user_data);
  if (self->minimize_to_tray && !self->quitting && self->tray_indicator) {
    gtk_widget_hide(widget);
    return TRUE;
  }
  return FALSE;
}

// Called when first Flutter frame received.
static void first_frame_cb(MyApplication* self, FlView* view) {
  gtk_widget_show(gtk_widget_get_toplevel(GTK_WIDGET(view)));
}

// Implements GApplication::activate.
static void my_application_activate(GApplication* application) {
  MyApplication* self = MY_APPLICATION(application);

  GtkWindow* window =
      GTK_WINDOW(gtk_application_window_new(GTK_APPLICATION(application)));
  self->main_window = window;
  gtk_window_set_default_size(window, 1040, 700);
  gtk_window_set_title(window, "MaterialDrop");

  g_signal_connect(window, "delete-event", G_CALLBACK(on_window_delete_event),
                   self);

  g_autoptr(FlDartProject) project = fl_dart_project_new();
  fl_dart_project_set_dart_entrypoint_arguments(
      project, self->dart_entrypoint_arguments);

  FlView* view = fl_view_new(project);
  GdkRGBA background_color;
  gdk_rgba_parse(&background_color, "#141218");
  fl_view_set_background_color(view, &background_color);
  gtk_widget_show(GTK_WIDGET(view));
  gtk_container_add(GTK_CONTAINER(window), GTK_WIDGET(view));

  g_signal_connect_swapped(view, "first-frame", G_CALLBACK(first_frame_cb),
                           self);
  gtk_widget_realize(GTK_WIDGET(view));

  fl_register_plugins(FL_PLUGIN_REGISTRY(view));

  FlEngine* engine = fl_view_get_engine(view);
  FlBinaryMessenger* messenger = fl_engine_get_binary_messenger(engine);
  g_autoptr(FlStandardMethodCodec) codec = fl_standard_method_codec_new();
  self->desktop_channel = fl_method_channel_new(
      messenger, "dev.materialdrop.flutter/desktop", FL_METHOD_CODEC(codec));
  fl_method_channel_set_method_call_handler(
      self->desktop_channel, desktop_method_call_handler, self, nullptr);

  gtk_widget_grab_focus(GTK_WIDGET(view));
}

// Implements GApplication::local_command_line.
static gboolean my_application_local_command_line(GApplication* application,
                                                  gchar*** arguments,
                                                  int* exit_status) {
  MyApplication* self = MY_APPLICATION(application);
  self->dart_entrypoint_arguments = g_strdupv(*arguments + 1);

  g_autoptr(GError) error = nullptr;
  if (!g_application_register(application, nullptr, &error)) {
    g_warning("Failed to register: %s", error->message);
    *exit_status = 1;
    return TRUE;
  }

  g_application_activate(application);
  *exit_status = 0;

  return TRUE;
}

// Implements GApplication::startup.
static void my_application_startup(GApplication* application) {
  G_APPLICATION_CLASS(my_application_parent_class)->startup(application);
}

// Implements GApplication::shutdown.
static void my_application_shutdown(GApplication* application) {
  G_APPLICATION_CLASS(my_application_parent_class)->shutdown(application);
}

// Implements GObject::dispose.
static void my_application_dispose(GObject* object) {
  MyApplication* self = MY_APPLICATION(object);
  g_clear_pointer(&self->dart_entrypoint_arguments, g_strfreev);
  g_clear_object(&self->desktop_channel);
  G_OBJECT_CLASS(my_application_parent_class)->dispose(object);
}

static void my_application_class_init(MyApplicationClass* klass) {
  G_APPLICATION_CLASS(klass)->activate = my_application_activate;
  G_APPLICATION_CLASS(klass)->local_command_line =
      my_application_local_command_line;
  G_APPLICATION_CLASS(klass)->startup = my_application_startup;
  G_APPLICATION_CLASS(klass)->shutdown = my_application_shutdown;
  G_OBJECT_CLASS(klass)->dispose = my_application_dispose;
}

static void my_application_init(MyApplication* self) {
  self->main_window = nullptr;
  self->desktop_channel = nullptr;
  self->tray_indicator = nullptr;
  self->tray_menu = nullptr;
  self->minimize_to_tray = true;
  self->auto_accept = false;
  self->sounds_enabled = true;
  self->suppress_toggle_signal = false;
  self->quitting = false;
}

MyApplication* my_application_new() {
  g_set_prgname(APPLICATION_ID);

  return MY_APPLICATION(g_object_new(my_application_get_type(),
                                     "application-id", APPLICATION_ID, "flags",
                                     G_APPLICATION_NON_UNIQUE, nullptr));
}
