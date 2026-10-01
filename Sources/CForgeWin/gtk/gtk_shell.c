// Linux shell of Forge (docs/adr/0013-linux-app.md): the GTK 4 window laid out as the design
// (docs/design, Main / Sketch / System artboards): a header bar with the document, undo / redo /
// save, the CommandManager tabs and the app menu; the icon ribbon; the FeatureManager tree;
// the PropertyManager with collapsible groups; over the viewport the heads-up view toolbar,
// the confirmation corner and the sketch badge; a status bar of cells. It implements the same
// C API as the Win32 shell (include/CForgeWin.h), so the Swift front end (Sources/ForgeWin)
// runs unchanged. Icons: gtk_icons.c; viewport: gtk_render.c.

#include "gtk_internal.h"

#include <stdlib.h>
#include <string.h>

// MARK: events

fw_event fw_event_make(int kind, int id, int sub) {
    fw_event e;
    memset(&e, 0, sizeof e);
    e.kind = kind;
    e.id = id;
    e.sub = sub;
    e.button = -1;
    return e;
}

void fw_emit(fw_app *a, fw_event e) {
    if (a->handler) a->handler(a->ctx, &e);
}

static int modsOf(GdkModifierType m) {
    return ((m & GDK_SHIFT_MASK) ? FW_MOD_SHIFT : 0) | ((m & GDK_CONTROL_MASK) ? FW_MOD_CTRL : 0) | ((m & GDK_ALT_MASK) ? FW_MOD_ALT : 0);
}

static int currentMods(GtkEventController *c) { return modsOf(gtk_event_controller_get_current_event_state(c)); }

/// '\n'-separated list → NULL-terminated vector (free with g_strfreev); "" → empty.
static char **splitLines(const char *s) {
    if (!s || !*s) return g_new0(char *, 1);
    return g_strsplit(s, "\n", -1);
}

static void clearBox(GtkWidget *box) {
    GtkWidget *c;
    while ((c = gtk_widget_get_first_child(box))) {
        if (GTK_IS_LIST_BOX(box)) gtk_list_box_remove(GTK_LIST_BOX(box), c);
        else gtk_box_remove(GTK_BOX(box), c);
    }
}

static GtkWidget *label(const char *text, const char *css) {
    GtkWidget *l = gtk_label_new(text ? text : "");
    gtk_label_set_xalign(GTK_LABEL(l), 0);
    if (css) gtk_widget_add_css_class(l, css);
    return l;
}

static GtkWidget *hbox(int spacing) { return gtk_box_new(GTK_ORIENTATION_HORIZONTAL, spacing); }
static GtkWidget *vbox(int spacing) { return gtk_box_new(GTK_ORIENTATION_VERTICAL, spacing); }

/// A flat button showing an icon.
static GtkWidget *iconButton(const char *icon, int size, const char *tooltip, const char *css) {
    GtkWidget *b = gtk_button_new();
    gtk_button_set_child(GTK_BUTTON(b), fw_icon_widget(icon, size));
    gtk_widget_add_css_class(b, css ? css : "forge-flat");
    if (tooltip) gtk_widget_set_tooltip_text(b, tooltip);
    return b;
}

// MARK: theme (the design's tokens, docs/design/gen.py LIGHT / DARK)

typedef struct {
    const char *chrome, *panel, *surface, *hairline, *text, *text2, *accent, *message, *warning, *error;
} Tokens;

static const Tokens kLight = {"#E9E9EC", "#FBFBFC", "#FFFFFF", "#D5D5DA", "#1D1D1F", "#5E5E66", "#1F5FD6", "#FFF4CE", "#B45309", "#C62F20"};
static const Tokens kDark = {"#1F2023", "#232427", "#2C2D31", "#3A3B40", "#EDEDEF", "#A6A6AE", "#4C8DFF", "#3B3522", "#F0A33A", "#FF6B5B"};

static const char *kCSS =
    "window.forge, window.forge .forge-chrome { background: @f_chrome; color: @f_text; }\n"
    "window.forge { font-size: 13px; }\n"
    "headerbar.forge-header { background: @f_chrome; box-shadow: none; border-bottom: none; min-height: 46px; padding: 0 6px; }\n"
    "headerbar.forge-header windowcontrols button { min-height: 22px; min-width: 22px; }\n"
    ".forge-doc-title { font-weight: 700; font-size: 13px; }\n"
    ".forge-doc-subtitle { color: @f_text2; font-size: 11px; }\n"
    ".forge-tabs { background: alpha(@f_text, 0.07); border-radius: 9px; padding: 3px; }\n"
    ".forge-tab { background: none; border: none; box-shadow: none; border-radius: 7px; padding: 3px 14px; min-height: 22px; color: @f_text2; }\n"
    ".forge-tab:hover { color: @f_text; }\n"
    ".forge-tab.active { background: @f_surface; color: @f_text; font-weight: 600; box-shadow: 0 1px 2px alpha(black, 0.14); }\n"
    ".forge-flat { background: none; border: none; box-shadow: none; padding: 4px; min-height: 0; min-width: 0; border-radius: 6px; color: @f_text2; }\n"
    ".forge-flat:hover { background: alpha(@f_text, 0.08); color: @f_text; }\n"
    ".forge-flat:disabled { color: alpha(@f_text, 0.3); }\n"
    ".forge-ribbon { background: @f_chrome; border-bottom: 1px solid @f_hairline; padding: 6px 8px 3px 8px; }\n"
    ".forge-group { padding: 0 8px; border-right: 1px solid @f_hairline; }\n"
    ".forge-group-title { color: @f_text2; font-size: 11px; margin-top: 2px; }\n"
    ".forge-rb { background: none; border: none; box-shadow: none; border-radius: 7px; min-height: 0; min-width: 0; color: @f_text; }\n"
    ".forge-rb:hover { background: alpha(@f_text, 0.08); }\n"
    ".forge-rb.active { background: alpha(@f_accent, 0.14); color: @f_accent; }\n"
    ".forge-rb:disabled { color: alpha(@f_text, 0.32); }\n"
    ".forge-rb.large { padding: 5px 5px 4px 5px; min-width: 60px; }\n"
    ".forge-rb.large label { font-size: 11px; }\n"
    ".forge-rb.small { padding: 1px 6px 1px 4px; }\n"
    ".forge-rb.small label { font-size: 12px; }\n"
    "menubutton.forge-flyout > button { background: none; border: none; box-shadow: none; padding: 2px 1px; min-width: 0; min-height: 0; color: @f_text2; border-radius: 4px; }\n"
    "menubutton.forge-flyout > button:hover { background: alpha(@f_text, 0.08); }\n"
    ".forge-left { background: @f_panel; border-right: 1px solid @f_hairline; }\n"
    ".forge-right { background: @f_panel; border-left: 1px solid @f_hairline; }\n"
    ".forge-search { background: @f_surface; border: 1px solid @f_hairline; border-radius: 7px; box-shadow: none; min-height: 28px; }\n"
    ".forge-tree, .forge-tree row { background: transparent; }\n"
    ".forge-tree row { padding: 0 6px; min-height: 0; outline: none; }\n"
    ".forge-tree row:hover { background: transparent; }\n"
    ".forge-node { padding: 4px 6px; border-radius: 6px; }\n"
    ".forge-node:hover { background: alpha(@f_text, 0.05); }\n"
    ".forge-node.selected { background: alpha(@f_accent, 0.14); color: @f_accent; }\n"
    ".forge-node.dim { color: alpha(@f_text, 0.42); }\n"
    ".forge-node.warning { color: @f_warning; }\n"
    ".forge-node.error { color: @f_error; }\n"
    ".forge-node.root label { font-weight: 700; }\n"
    ".forge-bar { background: @f_accent; min-height: 3px; border-radius: 2px; margin: 4px 6px; }\n"
    ".forge-headsup { background: @f_surface; border: 1px solid @f_hairline; border-radius: 10px; padding: 3px 5px; box-shadow: 0 3px 10px alpha(black, 0.12); }\n"
    ".forge-headsup menubutton > button { background: none; border: none; box-shadow: none; padding: 4px 3px; min-height: 0; min-width: 0; border-radius: 6px; color: @f_text2; }\n"
    ".forge-headsup menubutton > button:hover { background: alpha(@f_text, 0.08); color: @f_text; }\n"
    ".forge-sep { background: @f_hairline; min-width: 1px; margin: 5px 4px; }\n"
    ".forge-ok { background: @f_accent; color: white; border: none; border-radius: 9px; min-width: 40px; min-height: 40px; padding: 0; box-shadow: 0 3px 8px alpha(black, 0.22); }\n"
    ".forge-ok:hover { background: shade(@f_accent, 1.1); }\n"
    ".forge-cancel { background: @f_surface; color: @f_text; border: 1px solid @f_hairline; border-radius: 9px; min-width: 40px; min-height: 40px; padding: 0; box-shadow: 0 3px 8px alpha(black, 0.12); }\n"
    ".forge-badge { background: alpha(@f_surface, 0.94); border: 1px solid @f_hairline; border-radius: 8px; padding: 5px 10px; }\n"
    ".forge-badge-title { font-weight: 700; }\n"
    ".forge-badge-detail { color: @f_text2; }\n"
    ".forge-modify { background: @f_surface; border: 1px solid @f_hairline; border-radius: 8px; padding: 6px; box-shadow: 0 3px 10px alpha(black, 0.14); }\n"
    ".forge-pm-head { padding: 14px 14px 10px 14px; }\n"
    ".forge-pm-tile { background: alpha(@f_accent, 0.14); border-radius: 8px; min-width: 36px; min-height: 36px; }\n"
    ".forge-pm-title { font-size: 15px; font-weight: 700; }\n"
    ".forge-pm-subtitle { color: @f_text2; font-size: 11px; }\n"
    ".forge-pm-actions { padding: 0 14px 12px 14px; }\n"
    ".forge-pm-ok { background: @f_accent; color: white; border: none; border-radius: 6px; min-width: 34px; min-height: 28px; padding: 0; box-shadow: none; }\n"
    ".forge-pm-ok:hover { background: shade(@f_accent, 1.1); }\n"
    ".forge-pm-cancel { background: @f_surface; color: @f_text; border: 1px solid @f_hairline; border-radius: 6px; min-width: 34px; min-height: 28px; padding: 0; box-shadow: none; }\n"
    ".forge-message { background: @f_message; border-radius: 8px; padding: 8px 10px; margin: 0 14px 12px 14px; }\n"
    ".forge-section { border-top: 1px solid @f_hairline; }\n"
    ".forge-section-head { padding: 10px 14px 8px 10px; }\n"
    ".forge-section-title { font-weight: 700; }\n"
    ".forge-section-body { padding: 0 14px 12px 14px; }\n"
    ".forge-label { color: @f_text2; }\n"
    ".forge-field { background: @f_surface; border: 1px solid @f_hairline; border-radius: 6px; }\n"
    ".forge-field:focus-within { border-color: @f_accent; }\n"
    ".forge-field entry, .forge-field text { background: none; border: none; box-shadow: none; outline: none; font-family: monospace; min-height: 26px; }\n"
    ".forge-unit { color: @f_text2; font-size: 11px; margin-right: 8px; }\n"
    ".forge-list { background: @f_surface; border: 1px solid @f_hairline; border-radius: 7px; padding: 4px; }\n"
    ".forge-list.active { border: 2px solid @f_accent; padding: 3px; }\n"
    ".forge-chip { background: alpha(@f_accent, 0.12); color: @f_accent; border-radius: 5px; padding: 3px 8px; }\n"
    ".forge-placeholder { color: @f_text2; padding: 4px 6px; }\n"
    ".forge-note { color: @f_text2; font-size: 12px; }\n"
    ".forge-note.warning { color: @f_warning; }\n"
    ".forge-problem { color: @f_error; }\n"
    ".forge-pill { background: @f_surface; border: 1px solid @f_hairline; border-radius: 6px; box-shadow: none; padding: 3px 10px; min-height: 0; }\n"
    ".forge-right dropdown > button { background: @f_surface; border: 1px solid @f_hairline; border-radius: 6px; box-shadow: none; min-height: 26px; }\n"
    ".forge-status { background: @f_chrome; border-top: 1px solid @f_hairline; min-height: 26px; color: @f_text2; font-size: 12px; }\n"
    ".forge-status-left { padding: 0 12px; }\n"
    ".forge-status-cell { border-left: 1px solid @f_hairline; padding: 0 12px; }\n"
    ".forge-group.last { border-right: none; }\n"
    ".forge-disclosure { background: none; border: none; box-shadow: none; padding: 2px; min-height: 0; min-width: 0; color: @f_text2; border-radius: 4px; }\n"
    ".forge-disclosure:hover { background: alpha(@f_text, 0.08); }\n"
    ".forge-row { background: alpha(@f_text, 0.04); border-radius: 6px; padding: 4px 8px; }\n"
    ".forge-value { font-family: monospace; }\n"
    ".forge-app-menu > button { background: none; border: none; box-shadow: none; padding: 4px; min-height: 0; min-width: 0; border-radius: 6px; color: @f_text2; }\n"
    ".forge-app-menu > button:hover { background: alpha(@f_text, 0.08); color: @f_text; }\n"
    ".forge-status-cell.mono { font-family: monospace; }\n";

static void loadTheme(fw_app *a) {
    const Tokens *t = a->dark ? &kDark : &kLight;
    char *css = g_strdup_printf(
        "@define-color f_chrome %s;\n@define-color f_panel %s;\n@define-color f_surface %s;\n@define-color f_hairline %s;\n"
        "@define-color f_text %s;\n@define-color f_text2 %s;\n@define-color f_accent %s;\n@define-color f_message %s;\n"
        "@define-color f_warning %s;\n@define-color f_error %s;\n%s",
        t->chrome, t->panel, t->surface, t->hairline, t->text, t->text2, t->accent, t->message, t->warning, t->error, kCSS);
    GtkCssProvider *p = gtk_css_provider_new();
#if GTK_CHECK_VERSION(4, 12, 0)
    gtk_css_provider_load_from_string(p, css);
#else
    gtk_css_provider_load_from_data(p, css, -1);
#endif
    g_free(css);
    gtk_style_context_add_provider_for_display(gdk_display_get_default(), GTK_STYLE_PROVIDER(p), GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    g_object_unref(p);
    GdkRGBA accent;
    gdk_rgba_parse(&accent, t->accent);
    fw_icons_set_accent(accent);
}

/// Dark when asked (FORGE_THEME=dark) or when the desktop prefers it: GTK's prefer-dark setting
/// or a dark theme name (KDE's Breeze Dark sets both).
static int prefersDark(void) {
    const char *forced = g_getenv("FORGE_THEME");
    if (forced) return g_ascii_strcasecmp(forced, "dark") == 0;
    GtkSettings *s = gtk_settings_get_default();
    gboolean dark = FALSE;
    char *theme = NULL;
    g_object_get(s, "gtk-application-prefer-dark-theme", &dark, "gtk-theme-name", &theme, NULL);
    if (theme) {
        char *lower = g_ascii_strdown(theme, -1);
        if (strstr(lower, "dark")) dark = TRUE;
        g_free(lower);
        g_free(theme);
    }
    return dark;
}

// MARK: menus

static void onMenu(GSimpleAction *action, GVariant *param, gpointer data);

static void addAction(fw_app *a, int id, int checkable) {
    char name[16];
    snprintf(name, sizeof name, "m%d", id);
    GSimpleAction *act = checkable ? g_simple_action_new_stateful(name, NULL, g_variant_new_boolean(FALSE)) : g_simple_action_new(name, NULL);
    g_object_set_data(G_OBJECT(act), "forge-id", GINT_TO_POINTER(id));
    g_signal_connect(act, "activate", G_CALLBACK(onMenu), a);
    g_action_map_add_action(G_ACTION_MAP(a->actions), G_ACTION(act));
    g_object_unref(act);
}

static void item(GMenu *m, const char *title, int id) {
    char action[24];
    snprintf(action, sizeof action, "win.m%d", id);
    g_menu_append(m, title, action);
}

static void shortcut(GtkShortcutController *c, const char *accel, int id) {
    char action[24];
    snprintf(action, sizeof action, "win.m%d", id);
    gtk_shortcut_controller_add_shortcut(c, gtk_shortcut_new(gtk_shortcut_trigger_parse_string(accel), gtk_named_action_new(action)));
}

static GMenuModel *orientationMenu(void) {
    GMenu *m = g_menu_new(), *s1 = g_menu_new(), *s2 = g_menu_new();
    const char *names[] = {"Front", "Back", "Left", "Right", "Top", "Bottom", "Isometric", "Dimetric", "Trimetric", "Normal To"};
    for (int i = 0; i < 9; ++i) item(s1, names[i], FW_MENU_FRONT + i);
    item(s2, names[9], FW_MENU_NORMAL_TO);
    g_menu_append_section(m, NULL, G_MENU_MODEL(s1));
    g_menu_append_section(m, NULL, G_MENU_MODEL(s2));
    g_object_unref(s1);
    g_object_unref(s2);
    return G_MENU_MODEL(m);
}

static GMenuModel *displayMenu(void) {
    GMenu *m = g_menu_new();
    item(m, "Shaded With Edges", FW_MENU_SHADED_EDGES);
    item(m, "Shaded", FW_MENU_SHADED);
    item(m, "Wireframe", FW_MENU_WIREFRAME);
    item(m, "Hidden Lines Removed", FW_MENU_HIDDEN_LINES);
    return G_MENU_MODEL(m);
}

static GMenuModel *showMenu(void) {
    GMenu *m = g_menu_new();
    item(m, "Planes", FW_MENU_PLANES);
    item(m, "Sketch Relations", FW_MENU_RELATIONS);
    item(m, "Sketch Dimensions", FW_MENU_DIMENSIONS);
    return G_MENU_MODEL(m);
}

static GMenuModel *viewSettingsMenu(void) {
    GMenu *m = g_menu_new();
    item(m, "Perspective", FW_MENU_PERSPECTIVE);
    return G_MENU_MODEL(m);
}

/// The app menu (header bar): File, Edit, View and Help.
static GMenuModel *appMenu(void) {
    GMenu *m = g_menu_new(), *file = g_menu_new(), *exp = g_menu_new(), *edit = g_menu_new(), *view = g_menu_new(), *help = g_menu_new();
    item(file, "New Part", FW_MENU_NEW);
    item(file, "Open…", FW_MENU_OPEN);
    item(file, "Import STEP…", FW_MENU_IMPORT_STEP);
    item(file, "Save", FW_MENU_SAVE);
    item(file, "Save As…", FW_MENU_SAVE_AS);
    item(exp, "Export STEP…", FW_MENU_EXPORT_STEP);
    item(exp, "Export STL…", FW_MENU_EXPORT_STL);
    item(edit, "Undo", FW_MENU_UNDO);
    item(edit, "Redo", FW_MENU_REDO);
    GMenuModel *o = orientationMenu(), *d = displayMenu(), *sh = showMenu();
    g_menu_append_submenu(view, "Orientation", o);
    g_menu_append_submenu(view, "Display Style", d);
    g_menu_append_submenu(view, "Show", sh);
    item(view, "Zoom to Fit", FW_MENU_FIT);
    item(view, "Previous View", FW_MENU_PREVIOUS);
    item(view, "Perspective", FW_MENU_PERSPECTIVE);
    item(help, "About Forge", FW_MENU_ABOUT);
    item(help, "Quit", FW_MENU_EXIT);
    g_menu_append_section(m, NULL, G_MENU_MODEL(file));
    g_menu_append_section(m, NULL, G_MENU_MODEL(exp));
    g_menu_append_section(m, NULL, G_MENU_MODEL(edit));
    g_menu_append_section(m, NULL, G_MENU_MODEL(view));
    g_menu_append_section(m, NULL, G_MENU_MODEL(help));
    GObject *objs[] = {G_OBJECT(file), G_OBJECT(exp), G_OBJECT(edit), G_OBJECT(view), G_OBJECT(help), G_OBJECT(o), G_OBJECT(d), G_OBJECT(sh)};
    for (size_t i = 0; i < sizeof objs / sizeof objs[0]; ++i) g_object_unref(objs[i]);
    return G_MENU_MODEL(m);
}

static void buildActions(fw_app *a) {
    a->actions = g_simple_action_group_new();
    for (int id = FW_MENU_NEW; id <= FW_MENU_EXIT; ++id) addAction(a, id, 0);
    addAction(a, FW_MENU_IMPORT_STEP, 0);
    addAction(a, FW_MENU_UNDO, 0);
    addAction(a, FW_MENU_REDO, 0);
    for (int id = FW_MENU_FRONT; id <= FW_MENU_PREVIOUS; ++id) addAction(a, id, 0);
    for (int id = FW_MENU_PERSPECTIVE; id <= FW_MENU_DIMENSIONS; ++id) addAction(a, id, 1);
    for (int id = FW_MENU_SHADED_EDGES; id <= FW_MENU_HIDDEN_LINES; ++id) addAction(a, id, 1);
    addAction(a, FW_MENU_ABOUT, 0);
    gtk_widget_insert_action_group(a->window, "win", G_ACTION_GROUP(a->actions));

    GtkShortcutController *sc = GTK_SHORTCUT_CONTROLLER(gtk_shortcut_controller_new());
    gtk_shortcut_controller_set_scope(sc, GTK_SHORTCUT_SCOPE_GLOBAL);
    shortcut(sc, "<Control>n", FW_MENU_NEW);
    shortcut(sc, "<Control>o", FW_MENU_OPEN);
    shortcut(sc, "<Control>s", FW_MENU_SAVE);
    shortcut(sc, "<Control><Shift>s", FW_MENU_SAVE_AS);
    shortcut(sc, "<Control>z", FW_MENU_UNDO);
    shortcut(sc, "<Control>y", FW_MENU_REDO);
    shortcut(sc, "<Control><Shift>z", FW_MENU_REDO);
    shortcut(sc, "<Control>q", FW_MENU_EXIT);
    for (int i = 0; i < 8; ++i) {
        char accel[24];
        snprintf(accel, sizeof accel, "<Control>%d", i + 1);
        shortcut(sc, accel, i < 7 ? FW_MENU_FRONT + i : FW_MENU_NORMAL_TO);
    }
    gtk_widget_add_controller(a->window, GTK_EVENT_CONTROLLER(sc));
}

static void onActionButton(GtkButton *b, gpointer data) {
    fw_app *a = data;
    char name[16];
    snprintf(name, sizeof name, "m%d", GPOINTER_TO_INT(g_object_get_data(G_OBJECT(b), "forge-id")));
    g_action_group_activate_action(G_ACTION_GROUP(a->actions), name, NULL);
}

static GtkWidget *actionButton(fw_app *a, const char *icon, const char *tooltip, int id) {
    GtkWidget *b = iconButton(icon, 18, tooltip, "forge-flat");
    g_object_set_data(G_OBJECT(b), "forge-id", GINT_TO_POINTER(id));
    g_signal_connect(b, "clicked", G_CALLBACK(onActionButton), a);
    return b;
}

static GtkWidget *menuButton(const char *icon, int size, const char *tooltip, GMenuModel *model, gboolean arrow) {
    GtkWidget *m = gtk_menu_button_new();
    gtk_menu_button_set_menu_model(GTK_MENU_BUTTON(m), model);
    GtkWidget *content = hbox(1);
    gtk_box_append(GTK_BOX(content), fw_icon_widget(icon, size));
    if (arrow) gtk_box_append(GTK_BOX(content), fw_icon_widget("chevronDown", 9));
    gtk_menu_button_set_child(GTK_MENU_BUTTON(m), content);
    if (tooltip) gtk_widget_set_tooltip_text(m, tooltip);
    g_object_unref(model);
    return m;
}

static void onMenu(GSimpleAction *action, GVariant *param, gpointer data) {
    (void)param;
    fw_app *a = data;
    int id = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(action), "forge-id"));
    if (id == FW_MENU_EXIT) {  // handled by the shell, as on Windows
        fw_app_quit(a);
        return;
    }
    fw_emit(a, fw_event_make(FW_EV_MENU, id, 0));
}

// MARK: header bar (document, undo / redo / save, CommandManager tabs, app menu)

static void onTab(GtkButton *b, gpointer data) {
    fw_app *a = data;
    fw_emit(a, fw_event_make(FW_EV_TAB, GPOINTER_TO_INT(g_object_get_data(G_OBJECT(b), "forge-id")), 0));
}

void fw_set_tab(fw_app *a, int index) {
    for (int i = 0; i < 3; ++i) {
        if (i == index) gtk_widget_add_css_class(a->tabs[i], "active");
        else gtk_widget_remove_css_class(a->tabs[i], "active");
    }
}

static GtkWidget *buildHeader(fw_app *a) {
    a->header = gtk_header_bar_new();
    gtk_widget_add_css_class(a->header, "forge-header");

    GtkWidget *doc = hbox(9);
    gtk_widget_set_margin_start(doc, 6);
    gtk_box_append(GTK_BOX(doc), fw_icon_widget("part", 20));
    GtkWidget *names = vbox(0);
    gtk_widget_set_valign(names, GTK_ALIGN_CENTER);
    a->docTitle = label("Forge", "forge-doc-title");
    a->docSubtitle = label("Part", "forge-doc-subtitle");
    gtk_label_set_ellipsize(GTK_LABEL(a->docTitle), PANGO_ELLIPSIZE_END);
    gtk_label_set_max_width_chars(GTK_LABEL(a->docTitle), 28);
    gtk_box_append(GTK_BOX(names), a->docTitle);
    gtk_box_append(GTK_BOX(names), a->docSubtitle);
    gtk_box_append(GTK_BOX(doc), names);
    gtk_header_bar_pack_start(GTK_HEADER_BAR(a->header), doc);

    GtkWidget *edit = hbox(2);
    gtk_widget_set_margin_start(edit, 36);
    gtk_box_append(GTK_BOX(edit), actionButton(a, "undo", "Undo (Ctrl+Z)", FW_MENU_UNDO));
    gtk_box_append(GTK_BOX(edit), actionButton(a, "redo", "Redo (Ctrl+Y)", FW_MENU_REDO));
    gtk_box_append(GTK_BOX(edit), actionButton(a, "save", "Save (Ctrl+S)", FW_MENU_SAVE));
    gtk_header_bar_pack_start(GTK_HEADER_BAR(a->header), edit);

    GtkWidget *tabs = hbox(2);
    gtk_widget_add_css_class(tabs, "forge-tabs");
    gtk_widget_set_valign(tabs, GTK_ALIGN_CENTER);
    const char *names_[] = {"Features", "Sketch", "Evaluate"};
    for (int i = 0; i < 3; ++i) {
        a->tabs[i] = gtk_button_new_with_label(names_[i]);
        gtk_widget_add_css_class(a->tabs[i], "forge-tab");
        g_object_set_data(G_OBJECT(a->tabs[i]), "forge-id", GINT_TO_POINTER(i));
        g_signal_connect(a->tabs[i], "clicked", G_CALLBACK(onTab), a);
        gtk_box_append(GTK_BOX(tabs), a->tabs[i]);
    }
    fw_set_tab(a, 0);
    gtk_header_bar_set_title_widget(GTK_HEADER_BAR(a->header), tabs);

    GtkWidget *menu = menuButton("forge-menu", 18, "Menu", appMenu(), FALSE);
    gtk_widget_add_css_class(menu, "forge-app-menu");
    gtk_header_bar_pack_end(GTK_HEADER_BAR(a->header), menu);
    return a->header;
}

// MARK: ribbon

typedef struct {
    char *icon, *title, *help, *variants;
    int large, active, enabled, group;
} RibbonItem;

static void onRibbon(GtkButton *b, gpointer data) {
    fw_app *a = data;
    int id = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(b), "forge-id"));
    int sub = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(b), "forge-sub")) - 1;
    GtkWidget *pop = gtk_widget_get_ancestor(GTK_WIDGET(b), GTK_TYPE_POPOVER);
    if (pop) gtk_popover_popdown(GTK_POPOVER(pop));
    fw_emit(a, fw_event_make(FW_EV_RIBBON, id, sub));
}

/// A large button's label on two lines, broken at the space nearest the middle.
static char *twoLines(const char *title) {
    char *text = g_strdup(title ? title : "");
    size_t n = strlen(text), best = 0;
    for (size_t i = 0; i < n; ++i)
        if (text[i] == ' ' && (best == 0 || labs((long)i - (long)n / 2) < labs((long)best - (long)n / 2))) best = i;
    if (best > 0) text[best] = '\n';
    return text;
}

/// The ribbon button for `it` (a 26 px icon over a two-line label, or a 16 px icon beside the
/// label), with a flyout chevron for its variants.
static GtkWidget *ribbonButton(fw_app *a, const RibbonItem *it, int index) {
    GtkWidget *row = hbox(0);
    GtkWidget *b = gtk_button_new();
    GtkWidget *content;
    if (it->large) {
        content = vbox(3);
        gtk_box_append(GTK_BOX(content), fw_icon_widget(it->icon, 26));
        char *text = twoLines(it->title);
        GtkWidget *l = gtk_label_new(text);
        g_free(text);
        gtk_label_set_justify(GTK_LABEL(l), GTK_JUSTIFY_CENTER);
        gtk_label_set_lines(GTK_LABEL(l), 2);
        gtk_widget_set_valign(l, GTK_ALIGN_START);
        gtk_box_append(GTK_BOX(content), l);
    } else {
        content = hbox(6);
        gtk_box_append(GTK_BOX(content), fw_icon_widget(it->icon, 16));
        gtk_box_append(GTK_BOX(content), label(it->title, NULL));
    }
    gtk_button_set_child(GTK_BUTTON(b), content);
    gtk_widget_add_css_class(b, "forge-rb");
    gtk_widget_add_css_class(b, it->large ? "large" : "small");
    if (it->active) gtk_widget_add_css_class(b, "active");
    gtk_widget_set_sensitive(b, it->enabled);
    if (it->help && *it->help) gtk_widget_set_tooltip_text(b, it->help);
    g_object_set_data(G_OBJECT(b), "forge-id", GINT_TO_POINTER(index));
    g_object_set_data(G_OBJECT(b), "forge-sub", GINT_TO_POINTER(0));
    g_signal_connect(b, "clicked", G_CALLBACK(onRibbon), a);
    gtk_box_append(GTK_BOX(row), b);
    char **variants = splitLines(it->variants);
    if (variants[0]) {
        GtkWidget *menu = gtk_menu_button_new();
        gtk_menu_button_set_child(GTK_MENU_BUTTON(menu), fw_icon_widget("chevronDown", 9));
        gtk_widget_add_css_class(menu, "forge-flyout");
        gtk_widget_set_valign(menu, it->large ? GTK_ALIGN_START : GTK_ALIGN_CENTER);
        if (it->large) gtk_widget_set_margin_top(menu, 12);
        gtk_widget_set_sensitive(menu, it->enabled);
        gtk_widget_set_tooltip_text(menu, "More");
        GtkWidget *pop = gtk_popover_new(), *list = vbox(1);
        for (int k = 0; variants[k]; ++k) {
            GtkWidget *v = gtk_button_new_with_label(variants[k]);
            gtk_widget_add_css_class(v, "forge-flat");
            gtk_widget_set_halign(gtk_button_get_child(GTK_BUTTON(v)), GTK_ALIGN_START);
            g_object_set_data(G_OBJECT(v), "forge-id", GINT_TO_POINTER(index));
            g_object_set_data(G_OBJECT(v), "forge-sub", GINT_TO_POINTER(k + 1));
            g_signal_connect(v, "clicked", G_CALLBACK(onRibbon), a);
            gtk_box_append(GTK_BOX(list), v);
        }
        gtk_popover_set_child(GTK_POPOVER(pop), list);
        gtk_popover_set_has_arrow(GTK_POPOVER(pop), FALSE);
        gtk_menu_button_set_popover(GTK_MENU_BUTTON(menu), pop);
        gtk_box_append(GTK_BOX(row), menu);
    }
    g_strfreev(variants);
    return row;
}

static void freeRibbonItems(fw_app *a) {
    for (guint i = 0; i < a->pendingItems->len; ++i) {
        RibbonItem *it = &g_array_index(a->pendingItems, RibbonItem, i);
        g_free(it->icon);
        g_free(it->title);
        g_free(it->help);
        g_free(it->variants);
    }
    g_array_set_size(a->pendingItems, 0);
    g_ptr_array_set_size(a->pendingGroups, 0);
}

void fw_ribbon_begin(fw_app *a) { freeRibbonItems(a); }

void fw_ribbon_group(fw_app *a, const char *title) { g_ptr_array_add(a->pendingGroups, g_strdup(title)); }

void fw_ribbon_button(fw_app *a, const char *icon, const char *title, const char *help, int large, int active, int enabled, const char *variants) {
    RibbonItem it = {g_strdup(icon), g_strdup(title), g_strdup(help), g_strdup(variants), large, active, enabled, (int)a->pendingGroups->len - 1};
    g_array_append_val(a->pendingItems, it);
}

void fw_ribbon_end(fw_app *a) {
    // Rebuild only when something shown changed (the front end pushes on every model change).
    GString *key = g_string_new(NULL);
    for (guint g = 0; g < a->pendingGroups->len; ++g) g_string_append_printf(key, "[%s]", (char *)g_ptr_array_index(a->pendingGroups, g));
    for (guint i = 0; i < a->pendingItems->len; ++i) {
        RibbonItem *it = &g_array_index(a->pendingItems, RibbonItem, i);
        g_string_append_printf(key, "%d|%s|%s|%s|%d%d%d|%s;", it->group, it->icon, it->title, it->help, it->large, it->active, it->enabled, it->variants);
    }
    if (a->ribbonKey && strcmp(a->ribbonKey, key->str) == 0) {
        g_string_free(key, TRUE);
        return;
    }
    g_free(a->ribbonKey);
    a->ribbonKey = g_string_free(key, FALSE);
    clearBox(a->ribbon);
    GtkWidget *row = NULL, *column = NULL, *lastGroup = NULL;
    int group = -2, inColumn = 0;
    for (guint i = 0; i < a->pendingItems->len; ++i) {
        RibbonItem *it = &g_array_index(a->pendingItems, RibbonItem, i);
        if (it->group != group) {
            group = it->group;
            GtkWidget *outer = vbox(0);
            gtk_widget_add_css_class(outer, "forge-group");
            row = hbox(2);
            gtk_widget_set_vexpand(row, TRUE);
            gtk_widget_set_valign(row, GTK_ALIGN_START);
            gtk_box_append(GTK_BOX(outer), row);
            const char *title = group >= 0 && (guint)group < a->pendingGroups->len ? g_ptr_array_index(a->pendingGroups, group) : "";
            GtkWidget *t = label(title, "forge-group-title");
            gtk_label_set_xalign(GTK_LABEL(t), 0.5f);
            gtk_box_append(GTK_BOX(outer), t);
            gtk_box_append(GTK_BOX(a->ribbon), outer);
            lastGroup = outer;
            column = NULL;
            inColumn = 0;
        }
        GtkWidget *b = ribbonButton(a, it, (int)i);
        if (it->large) {
            column = NULL;
            gtk_box_append(GTK_BOX(row), b);
        } else {
            // Small buttons stack three to a column.
            if (!column || inColumn == 3) {
                column = vbox(0);
                gtk_widget_set_margin_start(column, 2);
                gtk_box_append(GTK_BOX(row), column);
                inColumn = 0;
            }
            gtk_box_append(GTK_BOX(column), b);
            ++inColumn;
        }
    }
    if (lastGroup) gtk_widget_add_css_class(lastGroup, "last");
}

// MARK: tree (FeatureManager)

typedef struct {
    int depth, state, selected;
    char *icon, *title, *tooltip, *menu;
} TreeNode;

static void freeNodes(GArray *nodes) {
    for (guint i = 0; i < nodes->len; ++i) {
        TreeNode *n = &g_array_index(nodes, TreeNode, i);
        g_free(n->icon);
        g_free(n->title);
        g_free(n->tooltip);
        g_free(n->menu);
    }
    g_array_set_size(nodes, 0);
}

static void onTreeMenuItem(GtkButton *b, gpointer data) {
    fw_app *a = data;
    int node = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(b), "forge-node"));
    int k = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(b), "forge-item"));
    GtkWidget *pop = gtk_widget_get_ancestor(GTK_WIDGET(b), GTK_TYPE_POPOVER);
    if (pop) gtk_popover_popdown(GTK_POPOVER(pop));
    fw_emit(a, fw_event_make(FW_EV_TREE_MENU, node, k));
}

static gboolean unparentLater(gpointer w) {
    gtk_widget_unparent(GTK_WIDGET(w));
    g_object_unref(w);
    return G_SOURCE_REMOVE;
}

static void onPopoverClosed(GtkPopover *p, gpointer data) {
    (void)data;
    g_idle_add(unparentLater, g_object_ref(p));
}

static void onTreeClick(GtkGestureClick *g, int n, double x, double y, gpointer data) {
    fw_app *a = data;
    GtkWidget *w = gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(g));
    int node = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(w), "forge-node"));
    guint button = gtk_gesture_single_get_current_button(GTK_GESTURE_SINGLE(g));
    if (button == GDK_BUTTON_SECONDARY) {
        if (node < 0 || (guint)node >= a->nodes->len) return;
        TreeNode *tn = &g_array_index(a->nodes, TreeNode, node);
        char **items = splitLines(tn->menu);
        if (items[0]) {
            GtkWidget *pop = gtk_popover_new(), *list = vbox(1);
            for (int k = 0; items[k]; ++k) {
                if (!strcmp(items[k], "Delete") || !strcmp(items[k], "What's Wrong?")) gtk_box_append(GTK_BOX(list), gtk_separator_new(GTK_ORIENTATION_HORIZONTAL));
                GtkWidget *b = gtk_button_new_with_label(items[k]);
                gtk_widget_add_css_class(b, "forge-flat");
                gtk_widget_set_halign(gtk_button_get_child(GTK_BUTTON(b)), GTK_ALIGN_START);
                g_object_set_data(G_OBJECT(b), "forge-node", GINT_TO_POINTER(node));
                g_object_set_data(G_OBJECT(b), "forge-item", GINT_TO_POINTER(k));
                g_signal_connect(b, "clicked", G_CALLBACK(onTreeMenuItem), a);
                gtk_box_append(GTK_BOX(list), b);
            }
            gtk_popover_set_child(GTK_POPOVER(pop), list);
            gtk_widget_set_parent(pop, w);
            gtk_popover_set_has_arrow(GTK_POPOVER(pop), FALSE);
            GdkRectangle r = {(int)x, (int)y, 1, 1};
            gtk_popover_set_pointing_to(GTK_POPOVER(pop), &r);
            g_signal_connect(pop, "closed", G_CALLBACK(onPopoverClosed), NULL);
            gtk_popover_popup(GTK_POPOVER(pop));
        }
        g_strfreev(items);
        return;
    }
    if (button != GDK_BUTTON_PRIMARY) return;
    if (n == 2) {
        fw_emit(a, fw_event_make(FW_EV_TREE_ACTIVATE, node, 0));
    } else {
        fw_event e = fw_event_make(FW_EV_TREE_SELECT, node, 0);
        e.mods = currentMods(GTK_EVENT_CONTROLLER(g));
        fw_emit(a, e);
    }
}

static char *collapseKey(const TreeNode *n) { return g_strdup_printf("%d:%s", n->depth, n->title ? n->title : ""); }

static void buildTree(fw_app *a);

static void onDisclosure(GtkButton *b, gpointer data) {
    fw_app *a = data;
    int node = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(b), "forge-node"));
    if (node < 0 || (guint)node >= a->nodes->len) return;
    char *key = collapseKey(&g_array_index(a->nodes, TreeNode, node));
    if (g_hash_table_contains(a->collapsed, key)) {
        g_hash_table_remove(a->collapsed, key);
        g_free(key);
    } else {
        g_hash_table_add(a->collapsed, key);
    }
    buildTree(a);
}

static void buildTree(fw_app *a) {
    clearBox(a->tree);
    int hideBelow = -1;  // descendants of a collapsed node are skipped
    for (guint i = 0; i < a->nodes->len; ++i) {
        TreeNode *n = &g_array_index(a->nodes, TreeNode, i);
        if (hideBelow >= 0) {
            if (n->depth > hideBelow) continue;
            hideBelow = -1;
        }
        int depth = n->depth < 0 ? 0 : n->depth;
        gboolean hasChildren = i + 1 < a->nodes->len && g_array_index(a->nodes, TreeNode, i + 1).depth > n->depth &&
                               n->state != FW_NODE_ROLLBACK_BAR;
        char *key = collapseKey(n);
        gboolean collapsed = hasChildren && g_hash_table_contains(a->collapsed, key);
        g_free(key);
        if (collapsed) hideBelow = n->depth;

        GtkWidget *row = hbox(6);
        gtk_widget_add_css_class(row, "forge-node");
        gtk_widget_set_margin_start(row, 18 * depth);
        if (n->state == FW_NODE_ROLLBACK_BAR) {
            gtk_widget_add_css_class(row, "rollback");
            GtkWidget *bar = hbox(0);
            gtk_widget_add_css_class(bar, "forge-bar");
            gtk_widget_set_hexpand(bar, TRUE);
            gtk_widget_set_valign(bar, GTK_ALIGN_CENTER);
            gtk_box_append(GTK_BOX(row), bar);
        } else {
            if (hasChildren) {
                GtkWidget *d = iconButton(collapsed ? "chevronRight" : "chevronDown", 10, collapsed ? "Expand" : "Collapse", "forge-disclosure");
                g_object_set_data(G_OBJECT(d), "forge-node", GINT_TO_POINTER((int)i));
                g_signal_connect(d, "clicked", G_CALLBACK(onDisclosure), a);
                gtk_box_append(GTK_BOX(row), d);
            } else {
                GtkWidget *space = hbox(0);
                gtk_widget_set_size_request(space, 14, -1);
                gtk_box_append(GTK_BOX(row), space);
            }
            if (n->icon && *n->icon) gtk_box_append(GTK_BOX(row), fw_icon_widget(n->icon, 16));
            GtkWidget *l = label(n->title, NULL);
            gtk_label_set_ellipsize(GTK_LABEL(l), PANGO_ELLIPSIZE_END);
            gtk_widget_set_hexpand(l, TRUE);
            gtk_box_append(GTK_BOX(row), l);
            if (n->state == FW_NODE_WARNING || n->state == FW_NODE_ERROR) gtk_box_append(GTK_BOX(row), fw_icon_widget("warning", 14));
        }
        switch (n->state) {
        case FW_NODE_SUPPRESSED:
        case FW_NODE_ROLLED_BACK: gtk_widget_add_css_class(row, "dim"); break;
        case FW_NODE_WARNING: gtk_widget_add_css_class(row, "warning"); break;
        case FW_NODE_ERROR: gtk_widget_add_css_class(row, "error"); break;
        default: break;
        }
        if (i == 0 && n->depth <= 0) gtk_widget_add_css_class(row, "root");
        if (n->selected) gtk_widget_add_css_class(row, "selected");
        if (n->tooltip && *n->tooltip) gtk_widget_set_tooltip_text(row, n->tooltip);
        else if (n->state == FW_NODE_ROLLBACK_BAR) gtk_widget_set_tooltip_text(row, "Rollback bar");
        g_object_set_data(G_OBJECT(row), "forge-node", GINT_TO_POINTER((int)i));
        GtkGesture *click = gtk_gesture_click_new();
        gtk_gesture_single_set_button(GTK_GESTURE_SINGLE(click), 0);
        g_signal_connect(click, "pressed", G_CALLBACK(onTreeClick), a);
        gtk_widget_add_controller(row, GTK_EVENT_CONTROLLER(click));
        gtk_list_box_append(GTK_LIST_BOX(a->tree), row);
    }
}

void fw_tree_begin(fw_app *a) { freeNodes(a->nodes); }

void fw_tree_node(fw_app *a, int depth, const char *icon, const char *title, const char *tooltip, int state, int selected, const char *menu) {
    TreeNode n = {depth, state, selected, g_strdup(icon), g_strdup(title), g_strdup(tooltip), g_strdup(menu)};
    g_array_append_val(a->nodes, n);
}

void fw_tree_end(fw_app *a) {
    GString *key = g_string_new(NULL);
    for (guint i = 0; i < a->nodes->len; ++i) {
        TreeNode *n = &g_array_index(a->nodes, TreeNode, i);
        g_string_append_printf(key, "%d|%s|%s|%s|%d%d|%s;", n->depth, n->icon, n->title, n->tooltip, n->state, n->selected, n->menu);
    }
    if (a->treeKey && strcmp(a->treeKey, key->str) == 0) {
        g_string_free(key, TRUE);
        return;
    }
    g_free(a->treeKey);
    a->treeKey = g_string_free(key, FALSE);
    buildTree(a);
}

static void onFilter(GtkSearchEntry *e, gpointer data) {
    fw_app *a = data;
    fw_event ev = fw_event_make(FW_EV_FILTER, 0, 0);
    ev.text = gtk_editable_get_text(GTK_EDITABLE(e));
    fw_emit(a, ev);
}

// MARK: PropertyManager

static void onPanelOK(GtkButton *b, gpointer data) {
    (void)b;
    fw_emit((fw_app *)data, fw_event_make(FW_EV_PANEL_OK, 0, 0));
}

static void onPanelCancel(GtkButton *b, gpointer data) {
    (void)b;
    fw_emit((fw_app *)data, fw_event_make(FW_EV_PANEL_CANCEL, 0, 0));
}

static int controlOf(GObject *o) { return GPOINTER_TO_INT(g_object_get_data(o, "forge-control")); }

static void onFieldChanged(GtkEditable *e, gpointer data) {
    fw_app *a = data;
    if (a->building) return;
    fw_event ev = fw_event_make(FW_EV_PANEL_TEXT, controlOf(G_OBJECT(e)), 0);
    ev.text = gtk_editable_get_text(e);
    fw_emit(a, ev);
}

static void onFieldActivate(GtkEntry *e, gpointer data) {
    fw_emit((fw_app *)data, fw_event_make(FW_EV_PANEL_SUBMIT, controlOf(G_OBJECT(e)), 0));
}

static void onFieldLeave(GtkEventControllerFocus *f, gpointer data) {
    fw_app *a = data;
    GtkWidget *w = gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(f));
    if (!a->building) fw_emit(a, fw_event_make(FW_EV_PANEL_SUBMIT, controlOf(G_OBJECT(w)), 0));
}

static void onCheck(GtkCheckButton *c, gpointer data) {
    fw_app *a = data;
    if (a->building) return;
    fw_emit(a, fw_event_make(FW_EV_PANEL_CHECK, controlOf(G_OBJECT(c)), gtk_check_button_get_active(c) ? 1 : 0));
}

static void onSection(GtkCheckButton *c, gpointer data) {
    fw_app *a = data;
    if (a->building) return;
    fw_emit(a, fw_event_make(FW_EV_PANEL_SECTION, GPOINTER_TO_INT(g_object_get_data(G_OBJECT(c), "forge-section")), gtk_check_button_get_active(c) ? 1 : 0));
}

static void onChoice(GObject *d, GParamSpec *p, gpointer data) {
    (void)p;
    fw_app *a = data;
    if (a->building) return;
    guint s = gtk_drop_down_get_selected(GTK_DROP_DOWN(d));
    fw_emit(a, fw_event_make(FW_EV_PANEL_CHOICE, controlOf(d), s == GTK_INVALID_LIST_POSITION ? -1 : (int)s));
}

static void onPanelButton(GtkButton *b, gpointer data) {
    fw_emit((fw_app *)data, fw_event_make(FW_EV_PANEL_BUTTON, controlOf(G_OBJECT(b)), GPOINTER_TO_INT(g_object_get_data(G_OBJECT(b), "forge-sub"))));
}

static void onRowDelete(GtkButton *b, gpointer data) {
    fw_emit((fw_app *)data, fw_event_make(FW_EV_PANEL_ROW_DELETE, controlOf(G_OBJECT(b)), GPOINTER_TO_INT(g_object_get_data(G_OBJECT(b), "forge-sub"))));
}

static void onListClick(GtkGestureClick *g, int n, double x, double y, gpointer data) {
    (void)n;
    (void)x;
    (void)y;
    GtkWidget *w = gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(g));
    fw_emit((fw_app *)data, fw_event_make(FW_EV_PANEL_LIST, controlOf(G_OBJECT(w)), 0));
}

/// A section's chevron: collapse or expand its body (remembered by title while the app runs).
static void onSectionDisclosure(GtkButton *b, gpointer data) {
    fw_app *a = data;
    GtkWidget *body = g_object_get_data(G_OBJECT(b), "forge-body");
    const char *title = g_object_get_data(G_OBJECT(b), "forge-title");
    gboolean open = !gtk_widget_get_visible(body);
    if (g_object_get_data(G_OBJECT(b), "forge-off")) return;  // a check group that is off stays closed
    gtk_widget_set_visible(body, open);
    if (title) {
        if (open) g_hash_table_remove(a->closedSections, title);
        else g_hash_table_add(a->closedSections, g_strdup(title));
    }
    gtk_button_set_child(b, fw_icon_widget(open ? "chevronDown" : "chevronRight", 10));
}

void fw_panel_begin(fw_app *a, const char *icon, const char *title, const char *subtitle, const char *message, int has_ok, int has_cancel) {
    a->building = 1;
    clearBox(a->panelBox);
    g_array_set_size(a->controls, 0);
    for (guint i = 0; i < a->sections->len; ++i) g_free(g_array_index(a->sections, PanelSection, i).title);
    g_array_set_size(a->sections, 0);

    GtkWidget *head = hbox(10);
    gtk_widget_add_css_class(head, "forge-pm-head");
    GtkWidget *tile = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_widget_add_css_class(tile, "forge-pm-tile");
    gtk_widget_set_valign(tile, GTK_ALIGN_START);
    gtk_widget_set_halign(tile, GTK_ALIGN_START);
    gtk_widget_set_hexpand(tile, FALSE);
    gtk_widget_set_size_request(tile, 36, 36);
    GtkWidget *glyph = fw_icon_widget(icon && *icon ? icon : "command", 22);
    gtk_widget_set_hexpand(glyph, TRUE);  // centred in the tile (which does not expand)
    gtk_box_append(GTK_BOX(tile), glyph);
    gtk_box_append(GTK_BOX(head), tile);
    GtkWidget *names = vbox(1);
    gtk_widget_set_valign(names, GTK_ALIGN_CENTER);
    gtk_widget_set_hexpand(names, TRUE);
    GtkWidget *t = label(title, "forge-pm-title");
    gtk_label_set_ellipsize(GTK_LABEL(t), PANGO_ELLIPSIZE_END);
    gtk_box_append(GTK_BOX(names), t);
    if (subtitle && *subtitle) {
        GtkWidget *s = label(subtitle, "forge-pm-subtitle");
        gtk_label_set_wrap(GTK_LABEL(s), TRUE);
        gtk_box_append(GTK_BOX(names), s);
    }
    gtk_box_append(GTK_BOX(head), names);
    gtk_box_append(GTK_BOX(a->panelBox), head);

    if (has_ok || has_cancel) {
        GtkWidget *actions = hbox(6);
        gtk_widget_add_css_class(actions, "forge-pm-actions");
        if (has_ok) {
            GtkWidget *ok = gtk_button_new();
            GtkWidget *check = fw_icon_widget("check", 16);
            fw_icon_widget_set_white(check);
            gtk_button_set_child(GTK_BUTTON(ok), check);
            gtk_widget_add_css_class(ok, "forge-pm-ok");
            gtk_widget_set_tooltip_text(ok, "OK");
            g_signal_connect(ok, "clicked", G_CALLBACK(onPanelOK), a);
            gtk_box_append(GTK_BOX(actions), ok);
        }
        if (has_cancel) {
            GtkWidget *c = iconButton("xmark", 14, "Cancel", "forge-pm-cancel");
            g_signal_connect(c, "clicked", G_CALLBACK(onPanelCancel), a);
            gtk_box_append(GTK_BOX(actions), c);
        }
        gtk_box_append(GTK_BOX(a->panelBox), actions);
    }
    if (message && *message) {
        GtkWidget *m = label(message, "forge-message");
        gtk_label_set_wrap(GTK_LABEL(m), TRUE);
        gtk_box_append(GTK_BOX(a->panelBox), m);
    }
    // Controls before the first section go in an untitled one.
    a->sectionBox = vbox(8);
    gtk_widget_add_css_class(a->sectionBox, "forge-section-body");
    gtk_box_append(GTK_BOX(a->panelBox), a->sectionBox);
}

void fw_panel_section(fw_app *a, const char *title, int toggle) {
    PanelSection s = {toggle, g_strdup(title)};
    g_array_append_val(a->sections, s);
    int index = (int)a->sections->len - 1;
    GtkWidget *section = vbox(0);
    gtk_widget_add_css_class(section, "forge-section");
    GtkWidget *body = vbox(8);
    gtk_widget_add_css_class(body, "forge-section-body");
    gboolean hasHead = toggle >= 0 || (title && *title);
    gboolean closed = title && g_hash_table_contains(a->closedSections, title);
    if (hasHead) {
        GtkWidget *head = hbox(6);
        gtk_widget_add_css_class(head, "forge-section-head");
        GtkWidget *chev = iconButton(closed || toggle == 0 ? "chevronRight" : "chevronDown", 10, NULL, "forge-disclosure");
        g_object_set_data(G_OBJECT(chev), "forge-body", body);
        g_object_set_data_full(G_OBJECT(chev), "forge-title", g_strdup(title ? title : ""), g_free);
        if (toggle == 0) g_object_set_data(G_OBJECT(chev), "forge-off", GINT_TO_POINTER(1));
        g_signal_connect(chev, "clicked", G_CALLBACK(onSectionDisclosure), a);
        gtk_box_append(GTK_BOX(head), chev);
        if (toggle >= 0) {
            GtkWidget *c = gtk_check_button_new_with_label(title);
            gtk_widget_add_css_class(c, "forge-section-title");
            gtk_check_button_set_active(GTK_CHECK_BUTTON(c), toggle == 1);
            g_object_set_data(G_OBJECT(c), "forge-section", GINT_TO_POINTER(index));
            g_signal_connect(c, "toggled", G_CALLBACK(onSection), a);
            gtk_box_append(GTK_BOX(head), c);
        } else {
            gtk_box_append(GTK_BOX(head), label(title, "forge-section-title"));
        }
        gtk_box_append(GTK_BOX(section), head);
    }
    gtk_widget_set_visible(body, toggle != 0 && !closed);
    gtk_box_append(GTK_BOX(section), body);
    gtk_box_append(GTK_BOX(a->panelBox), section);
    a->sectionBox = body;
}

static int addControl(fw_app *a, PanelKind kind, GtkWidget *main) {
    PanelControl c = {kind, (int)a->sections->len - 1, main};
    g_array_append_val(a->controls, c);
    int index = (int)a->controls->len - 1;
    if (main) g_object_set_data(G_OBJECT(main), "forge-control", GINT_TO_POINTER(index));
    return index;
}

/// A label on the left and `w` on the right (fields, choices, values).
static void labelled(fw_app *a, const char *text, GtkWidget *w) {
    if (!text || !*text) {
        gtk_widget_set_hexpand(w, TRUE);
        gtk_box_append(GTK_BOX(a->sectionBox), w);
        return;
    }
    GtkWidget *row = hbox(8);
    GtkWidget *l = label(text, "forge-label");
    gtk_widget_set_size_request(l, 96, -1);
    gtk_label_set_ellipsize(GTK_LABEL(l), PANGO_ELLIPSIZE_END);
    gtk_box_append(GTK_BOX(row), l);
    gtk_widget_set_hexpand(w, TRUE);
    gtk_box_append(GTK_BOX(row), w);
    gtk_box_append(GTK_BOX(a->sectionBox), row);
}

void fw_panel_field(fw_app *a, const char *label_, const char *unit, const char *value) {
    GtkWidget *field = hbox(0);
    gtk_widget_add_css_class(field, "forge-field");
    GtkWidget *e = gtk_entry_new();
    gtk_editable_set_text(GTK_EDITABLE(e), value ? value : "");
    gtk_editable_set_width_chars(GTK_EDITABLE(e), 6);
    gtk_widget_set_hexpand(e, TRUE);
    gtk_box_append(GTK_BOX(field), e);
    if (unit && *unit) {
        GtkWidget *u = label(unit, "forge-unit");
        gtk_widget_set_valign(u, GTK_ALIGN_CENTER);
        gtk_box_append(GTK_BOX(field), u);
    }
    addControl(a, PK_FIELD, e);
    g_signal_connect(e, "changed", G_CALLBACK(onFieldChanged), a);
    g_signal_connect(e, "activate", G_CALLBACK(onFieldActivate), a);
    GtkEventController *focus = gtk_event_controller_focus_new();
    g_signal_connect(focus, "leave", G_CALLBACK(onFieldLeave), a);
    gtk_widget_add_controller(e, focus);
    labelled(a, label_, field);
}

void fw_panel_check(fw_app *a, const char *label_, int value) {
    GtkWidget *c = gtk_check_button_new_with_label(label_);
    gtk_check_button_set_active(GTK_CHECK_BUTTON(c), value != 0);
    addControl(a, PK_CHECK, c);
    g_signal_connect(c, "toggled", G_CALLBACK(onCheck), a);
    gtk_box_append(GTK_BOX(a->sectionBox), c);
}

void fw_panel_choice(fw_app *a, const char *label_, const char *options, int selected) {
    char **opts = splitLines(options);
    GtkWidget *d = gtk_drop_down_new_from_strings((const char *const *)opts);
    g_strfreev(opts);
    gtk_drop_down_set_selected(GTK_DROP_DOWN(d), selected < 0 ? GTK_INVALID_LIST_POSITION : (guint)selected);
    addControl(a, PK_CHOICE, d);
    g_signal_connect(d, "notify::selected", G_CALLBACK(onChoice), a);
    labelled(a, label_, d);
}

/// The icon of a selection-box entry, from what it names.
static const char *chipIcon(const char *text) {
    char *lower = g_ascii_strdown(text, -1);
    const char *icon = strstr(lower, "sketch")  ? "sketch"
                     : strstr(lower, "edge")    ? "line"
                     : strstr(lower, "axis")    ? "axis"
                     : strstr(lower, "vertex") || strstr(lower, "point") ? "point"
                     : strstr(lower, "body")    ? "part"
                                                : "plane";
    g_free(lower);
    return icon;
}

void fw_panel_list(fw_app *a, const char *items, const char *placeholder, int active) {
    GtkWidget *box = vbox(3);
    gtk_widget_add_css_class(box, "forge-list");
    if (active) gtk_widget_add_css_class(box, "active");
    char **lines = splitLines(items);
    if (!lines[0]) gtk_box_append(GTK_BOX(box), label(placeholder, "forge-placeholder"));
    for (int i = 0; lines[i]; ++i) {
        GtkWidget *chip = hbox(6);
        gtk_widget_add_css_class(chip, "forge-chip");
        gtk_box_append(GTK_BOX(chip), fw_icon_widget(chipIcon(lines[i]), 14));
        GtkWidget *l = label(lines[i], NULL);
        gtk_label_set_ellipsize(GTK_LABEL(l), PANGO_ELLIPSIZE_END);
        gtk_box_append(GTK_BOX(chip), l);
        gtk_box_append(GTK_BOX(box), chip);
    }
    g_strfreev(lines);
    addControl(a, PK_LIST, box);
    GtkGesture *click = gtk_gesture_click_new();
    g_signal_connect(click, "pressed", G_CALLBACK(onListClick), a);
    gtk_widget_add_controller(box, GTK_EVENT_CONTROLLER(click));
    gtk_box_append(GTK_BOX(a->sectionBox), box);
}

void fw_panel_note(fw_app *a, const char *text, int warning) {
    GtkWidget *l = label(text, "forge-note");
    if (warning) gtk_widget_add_css_class(l, "warning");
    gtk_label_set_wrap(GTK_LABEL(l), TRUE);
    addControl(a, PK_NOTE, l);
    gtk_box_append(GTK_BOX(a->sectionBox), l);
}

void fw_panel_value(fw_app *a, const char *label_, const char *value) {
    GtkWidget *v = label(value, "forge-value");
    gtk_label_set_selectable(GTK_LABEL(v), TRUE);
    gtk_label_set_ellipsize(GTK_LABEL(v), PANGO_ELLIPSIZE_END);
    addControl(a, PK_VALUE, v);
    labelled(a, label_, v);
}

void fw_panel_buttons(fw_app *a, const char *titles) {
    GtkWidget *flow = gtk_flow_box_new();
    gtk_flow_box_set_selection_mode(GTK_FLOW_BOX(flow), GTK_SELECTION_NONE);
    gtk_flow_box_set_max_children_per_line(GTK_FLOW_BOX(flow), 4);
    gtk_flow_box_set_column_spacing(GTK_FLOW_BOX(flow), 6);
    gtk_flow_box_set_row_spacing(GTK_FLOW_BOX(flow), 6);
    gtk_widget_add_css_class(flow, "forge-buttons");
    int index = addControl(a, PK_BUTTONS, flow);
    char **t = splitLines(titles);
    for (int k = 0; t[k]; ++k) {
        GtkWidget *b = gtk_button_new_with_label(t[k]);
        gtk_widget_add_css_class(b, "forge-pill");
        g_object_set_data(G_OBJECT(b), "forge-control", GINT_TO_POINTER(index));
        g_object_set_data(G_OBJECT(b), "forge-sub", GINT_TO_POINTER(k));
        g_signal_connect(b, "clicked", G_CALLBACK(onPanelButton), a);
        gtk_flow_box_append(GTK_FLOW_BOX(flow), b);
    }
    g_strfreev(t);
    gtk_box_append(GTK_BOX(a->sectionBox), flow);
}

void fw_panel_rows(fw_app *a, const char *texts, const char *details, const char *problems, int deletable) {
    GtkWidget *box = vbox(4);
    int index = addControl(a, PK_ROWS, box);
    char **t = splitLines(texts), **d = splitLines(details), **p = splitLines(problems);
    guint nd = g_strv_length(d), np = g_strv_length(p);
    for (guint k = 0; t[k]; ++k) {
        GtkWidget *row = hbox(6);
        gtk_widget_add_css_class(row, "forge-row");
        GtkWidget *col = vbox(0);
        gtk_widget_set_hexpand(col, TRUE);
        gtk_widget_set_valign(col, GTK_ALIGN_CENTER);
        GtkWidget *l = label(t[k], k < np && !strcmp(p[k], "1") ? "forge-problem" : NULL);
        gtk_label_set_ellipsize(GTK_LABEL(l), PANGO_ELLIPSIZE_END);
        gtk_box_append(GTK_BOX(col), l);
        if (k < nd && *d[k]) gtk_box_append(GTK_BOX(col), label(d[k], "forge-note"));
        gtk_box_append(GTK_BOX(row), col);
        if (deletable) {
            GtkWidget *x = iconButton("xmark", 12, "Delete", "forge-flat");
            g_object_set_data(G_OBJECT(x), "forge-control", GINT_TO_POINTER(index));
            g_object_set_data(G_OBJECT(x), "forge-sub", GINT_TO_POINTER((int)k));
            g_signal_connect(x, "clicked", G_CALLBACK(onRowDelete), a);
            gtk_box_append(GTK_BOX(row), x);
        }
        gtk_box_append(GTK_BOX(box), row);
    }
    g_strfreev(t);
    g_strfreev(d);
    g_strfreev(p);
    gtk_box_append(GTK_BOX(a->sectionBox), box);
}

void fw_panel_end(fw_app *a) {
    // Hide the untitled first section when nothing went into it.
    GtkWidget *first = gtk_widget_get_first_child(a->panelBox);
    for (GtkWidget *w = first; w; w = gtk_widget_get_next_sibling(w))
        if (gtk_widget_has_css_class(w, "forge-section-body")) {
            gtk_widget_set_visible(w, gtk_widget_get_first_child(w) != NULL);
            break;
        }
    a->building = 0;
}

static PanelControl *control(fw_app *a, int i) { return i >= 0 && (guint)i < a->controls->len ? &g_array_index(a->controls, PanelControl, i) : NULL; }

/// Whether the keyboard focus is in `w` (a field being typed in keeps its text).
static gboolean focused(fw_app *a, GtkWidget *w) {
    GtkWidget *f = gtk_root_get_focus(GTK_ROOT(a->window));
    return f && (f == w || gtk_widget_is_ancestor(f, w));
}

void fw_panel_set_text(fw_app *a, int i, const char *value) {
    PanelControl *c = control(a, i);
    if (!c || c->kind != PK_FIELD || !c->main || focused(a, c->main)) return;
    if (strcmp(gtk_editable_get_text(GTK_EDITABLE(c->main)), value ? value : "") == 0) return;
    a->building = 1;
    gtk_editable_set_text(GTK_EDITABLE(c->main), value ? value : "");
    a->building = 0;
}

void fw_panel_set_check(fw_app *a, int i, int value) {
    PanelControl *c = control(a, i);
    if (!c || c->kind != PK_CHECK || !c->main) return;
    a->building = 1;
    gtk_check_button_set_active(GTK_CHECK_BUTTON(c->main), value != 0);
    a->building = 0;
}

void fw_panel_set_choice(fw_app *a, int i, int index) {
    PanelControl *c = control(a, i);
    if (!c || c->kind != PK_CHOICE || !c->main) return;
    a->building = 1;
    gtk_drop_down_set_selected(GTK_DROP_DOWN(c->main), index < 0 ? GTK_INVALID_LIST_POSITION : (guint)index);
    a->building = 0;
}

// MARK: viewport overlays (heads-up toolbar, confirmation corner, sketch badge, Modify box)

static GtkWidget *buildHeadsUp(fw_app *a) {
    GtkWidget *bar = hbox(1);
    gtk_widget_add_css_class(bar, "forge-headsup");
    gtk_widget_set_halign(bar, GTK_ALIGN_CENTER);
    gtk_widget_set_valign(bar, GTK_ALIGN_START);
    gtk_widget_set_margin_top(bar, 12);
    gtk_box_append(GTK_BOX(bar), actionButton(a, "zoomFit", "Zoom to Fit (F)", FW_MENU_FIT));
    gtk_box_append(GTK_BOX(bar), actionButton(a, "prevView", "Previous View", FW_MENU_PREVIOUS));
    GtkWidget *sep = hbox(0);
    gtk_widget_add_css_class(sep, "forge-sep");
    gtk_box_append(GTK_BOX(bar), sep);
    gtk_box_append(GTK_BOX(bar), menuButton("viewOrient", 18, "View Orientation", orientationMenu(), TRUE));
    gtk_box_append(GTK_BOX(bar), menuButton("displayStyle", 18, "Display Style", displayMenu(), TRUE));
    gtk_box_append(GTK_BOX(bar), menuButton("hideShow", 18, "Hide / Show Items", showMenu(), TRUE));
    gtk_box_append(GTK_BOX(bar), menuButton("viewSettings", 18, "View Settings", viewSettingsMenu(), TRUE));
    return bar;
}

static void onCornerOK(GtkButton *b, gpointer data) {
    (void)b;
    fw_app *a = data;
    fw_emit(a, fw_event_make(a->cornerMode == 1 ? FW_EV_PANEL_OK : FW_EV_CORNER_OK, 0, 0));
}

static void onCornerCancel(GtkButton *b, gpointer data) {
    (void)b;
    fw_app *a = data;
    fw_emit(a, fw_event_make(a->cornerMode == 1 ? FW_EV_PANEL_CANCEL : FW_EV_CORNER_CANCEL, 0, 0));
}

static GtkWidget *buildCorner(fw_app *a) {
    a->corner = hbox(8);
    gtk_widget_set_halign(a->corner, GTK_ALIGN_END);
    gtk_widget_set_valign(a->corner, GTK_ALIGN_START);
    gtk_widget_set_margin_top(a->corner, 12);
    gtk_widget_set_margin_end(a->corner, 16);
    a->cornerOK = gtk_button_new();
    GtkWidget *check = fw_icon_widget("check", 22);
    fw_icon_widget_set_white(check);
    gtk_button_set_child(GTK_BUTTON(a->cornerOK), check);
    gtk_widget_add_css_class(a->cornerOK, "forge-ok");
    g_signal_connect(a->cornerOK, "clicked", G_CALLBACK(onCornerOK), a);
    a->cornerCancel = iconButton("xmark", 20, "Cancel", "forge-cancel");
    g_signal_connect(a->cornerCancel, "clicked", G_CALLBACK(onCornerCancel), a);
    gtk_box_append(GTK_BOX(a->corner), a->cornerOK);
    gtk_box_append(GTK_BOX(a->corner), a->cornerCancel);
    gtk_widget_set_visible(a->corner, FALSE);
    return a->corner;
}

void fw_set_corner(fw_app *a, int mode) {
    a->cornerMode = mode;
    gtk_widget_set_visible(a->corner, mode != 0);
    gtk_widget_set_tooltip_text(a->cornerOK, mode == 2 ? "Exit Sketch" : "OK");
    gtk_widget_set_tooltip_text(a->cornerCancel, mode == 2 ? "Discard changes and exit the sketch" : "Cancel");
}

static GtkWidget *buildBadge(fw_app *a) {
    a->badge = hbox(8);
    gtk_widget_add_css_class(a->badge, "forge-badge");
    gtk_widget_set_halign(a->badge, GTK_ALIGN_START);
    gtk_widget_set_valign(a->badge, GTK_ALIGN_START);
    gtk_widget_set_margin_top(a->badge, 14);
    gtk_widget_set_margin_start(a->badge, 14);
    a->badgeIcon = hbox(0);
    a->badgeTitle = label("", "forge-badge-title");
    a->badgeDetail = label("", "forge-badge-detail");
    gtk_box_append(GTK_BOX(a->badge), a->badgeIcon);
    gtk_box_append(GTK_BOX(a->badge), a->badgeTitle);
    gtk_box_append(GTK_BOX(a->badge), a->badgeDetail);
    gtk_widget_set_visible(a->badge, FALSE);
    gtk_widget_set_can_target(a->badge, FALSE);
    return a->badge;
}

void fw_set_badge(fw_app *a, const char *icon, const char *title, const char *detail) {
    clearBox(a->badgeIcon);
    if (icon && *icon) gtk_box_append(GTK_BOX(a->badgeIcon), fw_icon_widget(icon, 16));
    gtk_label_set_text(GTK_LABEL(a->badgeTitle), title ? title : "");
    gtk_label_set_text(GTK_LABEL(a->badgeDetail), detail ? detail : "");
    gtk_widget_set_visible(a->badge, title && *title);
}

static void onModifyCommit(GtkWidget *w, gpointer data) {
    (void)w;
    fw_app *a = data;
    fw_event e = fw_event_make(FW_EV_EDIT_COMMIT, 0, 0);
    e.text = gtk_editable_get_text(GTK_EDITABLE(a->modifyEntry));
    fw_emit(a, e);
}

static void onModifyCancel(GtkWidget *w, gpointer data) {
    (void)w;
    fw_emit((fw_app *)data, fw_event_make(FW_EV_EDIT_CANCEL, 0, 0));
}

static gboolean onModifyKey(GtkEventControllerKey *k, guint keyval, guint code, GdkModifierType state, gpointer data) {
    (void)k;
    (void)code;
    (void)state;
    if (keyval == GDK_KEY_Escape) {
        onModifyCancel(NULL, data);
        return TRUE;
    }
    return FALSE;
}

void fw_edit_show(fw_app *a, int x, int y, const char *label_, const char *value) {
    gtk_label_set_text(GTK_LABEL(a->modifyLabel), label_ ? label_ : "");
    gtk_editable_set_text(GTK_EDITABLE(a->modifyEntry), value ? value : "");
    float s = a->scale > 0 ? a->scale : 1;
    gtk_widget_set_margin_start(a->modify, (int)(x / s));
    gtk_widget_set_margin_top(a->modify, (int)(y / s));
    gtk_widget_set_visible(a->modify, TRUE);
    gtk_widget_grab_focus(a->modifyEntry);
    gtk_editable_select_region(GTK_EDITABLE(a->modifyEntry), 0, -1);
}

void fw_edit_hide(fw_app *a) {
    gtk_widget_set_visible(a->modify, FALSE);
    fw_view_focus(a);
}

static GtkWidget *buildModify(fw_app *a) {
    a->modify = hbox(6);
    gtk_widget_add_css_class(a->modify, "forge-modify");
    gtk_widget_set_halign(a->modify, GTK_ALIGN_START);
    gtk_widget_set_valign(a->modify, GTK_ALIGN_START);
    a->modifyLabel = label("", "forge-label");
    GtkWidget *field = hbox(0);
    gtk_widget_add_css_class(field, "forge-field");
    a->modifyEntry = gtk_entry_new();
    gtk_editable_set_width_chars(GTK_EDITABLE(a->modifyEntry), 10);
    gtk_box_append(GTK_BOX(field), a->modifyEntry);
    g_signal_connect(a->modifyEntry, "activate", G_CALLBACK(onModifyCommit), a);
    GtkEventController *keys = gtk_event_controller_key_new();
    g_signal_connect(keys, "key-pressed", G_CALLBACK(onModifyKey), a);
    gtk_widget_add_controller(a->modifyEntry, keys);
    GtkWidget *ok = gtk_button_new();
    GtkWidget *check = fw_icon_widget("check", 14);
    fw_icon_widget_set_white(check);
    gtk_button_set_child(GTK_BUTTON(ok), check);
    gtk_widget_add_css_class(ok, "forge-pm-ok");
    gtk_widget_set_tooltip_text(ok, "OK");
    GtkWidget *cancel = iconButton("xmark", 12, "Cancel", "forge-pm-cancel");
    g_signal_connect(ok, "clicked", G_CALLBACK(onModifyCommit), a);
    g_signal_connect(cancel, "clicked", G_CALLBACK(onModifyCancel), a);
    gtk_box_append(GTK_BOX(a->modify), a->modifyLabel);
    gtk_box_append(GTK_BOX(a->modify), field);
    gtk_box_append(GTK_BOX(a->modify), ok);
    gtk_box_append(GTK_BOX(a->modify), cancel);
    gtk_widget_set_visible(a->modify, FALSE);
    return a->modify;
}

// MARK: status bar

void fw_set_status(fw_app *a, const char *left, const char *middle, const char *right) {
    const char *texts[3] = {left, middle, right};
    for (int i = 0; i < 3; ++i) {
        gtk_label_set_text(GTK_LABEL(a->status[i]), texts[i] ? texts[i] : "");
        if (i > 0) gtk_widget_set_visible(a->statusCells[i], texts[i] && *texts[i]);
    }
}

static GtkWidget *buildStatus(fw_app *a) {
    GtkWidget *status = hbox(0);
    gtk_widget_add_css_class(status, "forge-status");
    GtkWidget *left = hbox(8);
    gtk_widget_add_css_class(left, "forge-status-left");
    gtk_widget_set_hexpand(left, TRUE);
    gtk_box_append(GTK_BOX(left), fw_icon_widget("command", 14));
    a->status[0] = label("", NULL);
    gtk_label_set_ellipsize(GTK_LABEL(a->status[0]), PANGO_ELLIPSIZE_END);
    gtk_widget_set_hexpand(a->status[0], TRUE);
    gtk_box_append(GTK_BOX(left), a->status[0]);
    gtk_box_append(GTK_BOX(status), left);
    a->statusCells[0] = left;
    for (int i = 1; i < 3; ++i) {
        GtkWidget *cell = hbox(0);
        gtk_widget_add_css_class(cell, "forge-status-cell");
        if (i == 1) gtk_widget_add_css_class(cell, "mono");
        a->status[i] = label("", NULL);
        gtk_widget_set_valign(a->status[i], GTK_ALIGN_CENTER);
        gtk_box_append(GTK_BOX(cell), a->status[i]);
        gtk_widget_set_visible(cell, FALSE);
        gtk_box_append(GTK_BOX(status), cell);
        a->statusCells[i] = cell;
    }
    return status;
}

// MARK: dialogs (the GTK dialogs are asynchronous: wait for them in a nested loop)

typedef struct {
    int done;
    int button;
    char *path;
} DialogResult;

static void wait(DialogResult *r) {
    while (!r->done) g_main_context_iteration(NULL, TRUE);
}

static void onAlert(GObject *src, GAsyncResult *res, gpointer data) {
    DialogResult *r = data;
    r->button = gtk_alert_dialog_choose_finish(GTK_ALERT_DIALOG(src), res, NULL);
    r->done = 1;
}

int fw_confirm(fw_app *a, const char *title, const char *message, const char *yes, const char *no) {
    GtkAlertDialog *d = gtk_alert_dialog_new("%s", title ? title : "");
    gtk_alert_dialog_set_detail(d, message ? message : "");
    const char *buttons[] = {no ? no : "Cancel", yes ? yes : "OK", NULL};
    gtk_alert_dialog_set_buttons(d, buttons);
    gtk_alert_dialog_set_cancel_button(d, 0);
    gtk_alert_dialog_set_default_button(d, 1);
    DialogResult r = {0, -1, NULL};
    gtk_alert_dialog_choose(d, GTK_WINDOW(a->window), NULL, onAlert, &r);
    wait(&r);
    g_object_unref(d);
    return r.button == 1;
}

static void onNameResponse(GtkDialog *dialog, int response, gpointer data) {
    (void)dialog;
    DialogResult *r = data;
    r->button = response;
    r->done = 1;
}

char *fw_name_dialog(fw_app *a, const char *title, const char *current_name) {
    GtkWidget *dialog = gtk_dialog_new_with_buttons(title ? title : "Rename", GTK_WINDOW(a->window),
        GTK_DIALOG_MODAL | GTK_DIALOG_DESTROY_WITH_PARENT,
        "Cancel", GTK_RESPONSE_CANCEL, "Rename", GTK_RESPONSE_ACCEPT, NULL);
    GtkWidget *entry = gtk_entry_new();
    gtk_editable_set_text(GTK_EDITABLE(entry), current_name ? current_name : "");
    gtk_entry_set_activates_default(GTK_ENTRY(entry), TRUE);
    gtk_widget_set_margin_start(entry, 16);
    gtk_widget_set_margin_end(entry, 16);
    gtk_widget_set_margin_top(entry, 16);
    gtk_widget_set_margin_bottom(entry, 16);
    gtk_widget_set_size_request(entry, 300, -1);
    gtk_accessible_update_property(GTK_ACCESSIBLE(entry), GTK_ACCESSIBLE_PROPERTY_LABEL, "Name", -1);
    gtk_box_append(GTK_BOX(gtk_dialog_get_content_area(GTK_DIALOG(dialog))), entry);
    gtk_dialog_set_default_response(GTK_DIALOG(dialog), GTK_RESPONSE_ACCEPT);
    DialogResult r = {0, GTK_RESPONSE_CANCEL, NULL};
    g_signal_connect(dialog, "response", G_CALLBACK(onNameResponse), &r);
    gtk_window_present(GTK_WINDOW(dialog));
    gtk_widget_grab_focus(entry);
    gtk_editable_select_region(GTK_EDITABLE(entry), 0, -1);
    wait(&r);
    char *name = r.button == GTK_RESPONSE_ACCEPT ? strdup(gtk_editable_get_text(GTK_EDITABLE(entry))) : NULL;
    gtk_window_destroy(GTK_WINDOW(dialog));
    return name;
}

void fw_message(fw_app *a, const char *title, const char *message, int error) {
    (void)error;
    GtkAlertDialog *d = gtk_alert_dialog_new("%s", title ? title : "");
    gtk_alert_dialog_set_detail(d, message ? message : "");
    DialogResult r = {0, -1, NULL};
    gtk_alert_dialog_choose(d, GTK_WINDOW(a->window), NULL, onAlert, &r);
    wait(&r);
    g_object_unref(d);
}

static void onFile(GObject *src, GAsyncResult *res, gpointer data) {
    DialogResult *r = data;
    GFile *f = r->button == 1 ? gtk_file_dialog_select_folder_finish(GTK_FILE_DIALOG(src), res, NULL)
        : r->button == 2 ? gtk_file_dialog_open_finish(GTK_FILE_DIALOG(src), res, NULL)
        : gtk_file_dialog_save_finish(GTK_FILE_DIALOG(src), res, NULL);
    if (f) {
        r->path = g_file_get_path(f);
        g_object_unref(f);
    }
    r->done = 1;
}

static char *mallocCopy(char *s) {
    if (!s) return NULL;
    char *out = strdup(s);
    g_free(s);
    return out;
}

char *fw_save_dialog(fw_app *a, const char *suggested_name) {
    GtkFileDialog *d = gtk_file_dialog_new();
    gtk_file_dialog_set_title(d, "Save");
    if (suggested_name && *suggested_name) gtk_file_dialog_set_initial_name(d, suggested_name);
    DialogResult r = {0, 0, NULL};
    gtk_file_dialog_save(d, GTK_WINDOW(a->window), NULL, onFile, &r);
    wait(&r);
    g_object_unref(d);
    return mallocCopy(r.path);
}

char *fw_open_dialog(fw_app *a) {
    // A .forgepart document is a folder.
    GtkFileDialog *d = gtk_file_dialog_new();
    gtk_file_dialog_set_title(d, "Open a Forge part (.forgepart folder)");
    DialogResult r = {0, 1, NULL};
    gtk_file_dialog_select_folder(d, GTK_WINDOW(a->window), NULL, onFile, &r);
    wait(&r);
    g_object_unref(d);
    return mallocCopy(r.path);
}

char *fw_import_step_dialog(fw_app *a) {
    GtkFileDialog *d = gtk_file_dialog_new();
    gtk_file_dialog_set_title(d, "Import STEP solids");
    GtkFileFilter *filter = gtk_file_filter_new();
    gtk_file_filter_set_name(filter, "STEP files");
    gtk_file_filter_add_pattern(filter, "*.step");
    gtk_file_filter_add_pattern(filter, "*.stp");
    gtk_file_filter_add_pattern(filter, "*.STEP");
    gtk_file_filter_add_pattern(filter, "*.STP");
    gtk_file_dialog_set_default_filter(d, filter);
    g_object_unref(filter);
    DialogResult r = {0, 2, NULL};
    gtk_file_dialog_open(d, GTK_WINDOW(a->window), NULL, onFile, &r);
    wait(&r);
    g_object_unref(d);
    return mallocCopy(r.path);
}

void fw_free(void *p) { free(p); }

uint8_t *fw_capture(fw_app *a, int *width, int *height) {
    GtkWidget *w = a->window;
    int W = gtk_widget_get_width(w), H = gtk_widget_get_height(w);
    GtkNative *native = gtk_widget_get_native(w);
    GskRenderer *renderer = native ? gtk_native_get_renderer(native) : NULL;
    if (W <= 0 || H <= 0 || !renderer) return NULL;
    GdkPaintable *paintable = gtk_widget_paintable_new(w);
    GtkSnapshot *snap = gtk_snapshot_new();
    gdk_paintable_snapshot(paintable, GDK_SNAPSHOT(snap), W, H);
    GskRenderNode *node = gtk_snapshot_free_to_node(snap);
    g_object_unref(paintable);
    if (!node) return NULL;
    graphene_rect_t area = GRAPHENE_RECT_INIT(0, 0, (float)W, (float)H);
    GdkTexture *t = gsk_renderer_render_texture(renderer, node, &area);
    gsk_render_node_unref(node);
    if (!t) return NULL;
    int tw = gdk_texture_get_width(t), th = gdk_texture_get_height(t);
    uint8_t *bgra = malloc((size_t)tw * th * 4);
    gdk_texture_download(t, bgra, (size_t)tw * 4);  // premultiplied B, G, R, A (Cairo ARGB32 in memory)
    g_object_unref(t);
    for (size_t i = 0; i < (size_t)tw * th; ++i) {
        uint8_t b = bgra[i * 4], r = bgra[i * 4 + 2];
        bgra[i * 4] = r;
        bgra[i * 4 + 2] = b;
    }
    *width = tw;
    *height = th;
    return bgra;
}

// MARK: application

static void onDestroy(GtkWidget *w, gpointer data) {
    (void)w;
    fw_app *a = data;
    a->quit = 1;
    a->window = NULL;
    a->view = NULL;
}

static gboolean onClose(GtkWindow *w, gpointer data) {
    (void)w;
    fw_app *a = data;
    fw_emit(a, fw_event_make(FW_EV_CLOSE, 0, 0));
    a->quit = 1;
    return FALSE;
}

static gboolean onTick(gpointer data) {
    fw_app *a = data;
    if (a->quit) return G_SOURCE_REMOVE;
    fw_emit(a, fw_event_make(FW_EV_TICK, 0, 0));
    return G_SOURCE_CONTINUE;
}

fw_app *fw_app_create(const char *title, fw_handler handler, void *ctx) {
    if (!gtk_init_check()) return NULL;
    g_set_prgname("forge");
    g_set_application_name("Forge");
    fw_app *a = g_new0(fw_app, 1);
    a->handler = handler;
    a->ctx = ctx;
    a->scale = 1;
    a->dark = prefersDark();
    // Forge draws its own chrome from the design's tokens; GTK's Adwaita (in the matching
    // variant) supplies the popovers, check boxes and drop-downs, whatever the desktop theme.
    // GTK_THEME overrides.
    if (!g_getenv("GTK_THEME")) g_object_set(gtk_settings_get_default(), "gtk-theme-name", "Adwaita", "gtk-application-prefer-dark-theme", a->dark, NULL);
    loadTheme(a);
    fw_icon_define(a, "forge-menu", "s M 4 7 L 20 7 M 4 12 L 20 12 M 4 17 L 20 17");
    a->pendingGroups = g_ptr_array_new_with_free_func(g_free);
    a->pendingItems = g_array_new(FALSE, TRUE, sizeof(RibbonItem));
    a->nodes = g_array_new(FALSE, TRUE, sizeof(TreeNode));
    a->collapsed = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, NULL);
    a->controls = g_array_new(FALSE, TRUE, sizeof(PanelControl));
    a->sections = g_array_new(FALSE, TRUE, sizeof(PanelSection));
    a->closedSections = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, NULL);
    a->renderer = fw_renderer_create();

    a->window = gtk_window_new();
    gtk_widget_add_css_class(a->window, "forge");
    gtk_window_set_title(GTK_WINDOW(a->window), title ? title : "Forge");
    gtk_window_set_icon_name(GTK_WINDOW(a->window), "forge");
    gtk_window_set_default_size(GTK_WINDOW(a->window), 1440, 900);
    g_signal_connect(a->window, "close-request", G_CALLBACK(onClose), a);
    g_signal_connect(a->window, "destroy", G_CALLBACK(onDestroy), a);
    buildActions(a);
    gtk_window_set_titlebar(GTK_WINDOW(a->window), buildHeader(a));

    GtkWidget *root = vbox(0);
    gtk_widget_add_css_class(root, "forge-chrome");

    a->ribbon = hbox(0);
    GtkWidget *ribbonScroll = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(ribbonScroll), GTK_POLICY_AUTOMATIC, GTK_POLICY_NEVER);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(ribbonScroll), a->ribbon);
    gtk_widget_add_css_class(ribbonScroll, "forge-ribbon");
    gtk_widget_set_size_request(ribbonScroll, -1, 92);
    gtk_widget_set_vexpand(ribbonScroll, FALSE);
    gtk_box_append(GTK_BOX(root), ribbonScroll);

    GtkWidget *middle = hbox(0);
    gtk_widget_set_vexpand(middle, TRUE);

    GtkWidget *left = vbox(6);
    gtk_widget_add_css_class(left, "forge-left");
    gtk_widget_set_size_request(left, 272, -1);
    gtk_widget_set_hexpand(left, FALSE);
    a->filter = gtk_search_entry_new();
    gtk_search_entry_set_placeholder_text(GTK_SEARCH_ENTRY(a->filter), "Filter features");
    gtk_widget_add_css_class(a->filter, "forge-search");
    gtk_widget_set_margin_start(a->filter, 10);
    gtk_widget_set_margin_end(a->filter, 10);
    gtk_widget_set_margin_top(a->filter, 10);
    g_signal_connect(a->filter, "search-changed", G_CALLBACK(onFilter), a);
    gtk_box_append(GTK_BOX(left), a->filter);
    a->tree = gtk_list_box_new();
    gtk_list_box_set_selection_mode(GTK_LIST_BOX(a->tree), GTK_SELECTION_NONE);
    gtk_widget_add_css_class(a->tree, "forge-tree");
    GtkWidget *treeScroll = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(treeScroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(treeScroll), a->tree);
    gtk_widget_set_vexpand(treeScroll, TRUE);
    gtk_box_append(GTK_BOX(left), treeScroll);
    gtk_box_append(GTK_BOX(middle), left);

    a->overlay = gtk_overlay_new();
    gtk_widget_set_hexpand(a->overlay, TRUE);
    a->view = fw_render_create_view(a);
    gtk_overlay_set_child(GTK_OVERLAY(a->overlay), a->view);
    gtk_overlay_add_overlay(GTK_OVERLAY(a->overlay), buildHeadsUp(a));
    gtk_overlay_add_overlay(GTK_OVERLAY(a->overlay), buildBadge(a));
    gtk_overlay_add_overlay(GTK_OVERLAY(a->overlay), buildCorner(a));
    gtk_overlay_add_overlay(GTK_OVERLAY(a->overlay), buildModify(a));
    gtk_box_append(GTK_BOX(middle), a->overlay);

    a->panelBox = vbox(0);
    a->panel = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(a->panel), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(a->panel), a->panelBox);
    gtk_widget_add_css_class(a->panel, "forge-right");
    gtk_widget_set_size_request(a->panel, 312, -1);
    gtk_widget_set_hexpand(a->panel, FALSE);  // its fields expand within it, not into the viewport
    gtk_box_append(GTK_BOX(middle), a->panel);
    gtk_box_append(GTK_BOX(root), middle);

    gtk_box_append(GTK_BOX(root), buildStatus(a));

    gtk_window_set_child(GTK_WINDOW(a->window), root);
    g_timeout_add(33, onTick, a);
    return a;
}

void fw_app_show(fw_app *a) {
    gtk_window_present(GTK_WINDOW(a->window));
    fw_view_focus(a);
}

static gboolean wake(gpointer data) {
    *(int *)data = 1;
    return G_SOURCE_REMOVE;
}

int fw_app_pump(fw_app *a, int timeout_ms) {
    if (a->quit) return 0;
    int woke = 0;
    guint id = g_timeout_add(timeout_ms > 0 ? (guint)timeout_ms : 1, wake, &woke);
    g_main_context_iteration(NULL, TRUE);
    while (g_main_context_iteration(NULL, FALSE)) {}
    if (!woke) g_source_remove(id);
    return !a->quit;
}

void fw_app_destroy(fw_app *a) {
    if (!a) return;
    if (a->window) gtk_window_destroy(GTK_WINDOW(a->window));
    while (g_main_context_iteration(NULL, FALSE)) {}
    fw_renderer_destroy(a->renderer);
    freeRibbonItems(a);
    g_ptr_array_unref(a->pendingGroups);
    g_array_unref(a->pendingItems);
    freeNodes(a->nodes);
    g_array_unref(a->nodes);
    g_hash_table_unref(a->collapsed);
    g_array_unref(a->controls);
    for (guint i = 0; i < a->sections->len; ++i) g_free(g_array_index(a->sections, PanelSection, i).title);
    g_array_unref(a->sections);
    g_hash_table_unref(a->closedSections);
    g_clear_object(&a->actions);
    g_free(a->ribbonKey);
    g_free(a->treeKey);
    g_free(a);
}

int fw_capabilities(fw_app *a) { return FW_CAN_CORNER | FW_CAN_BADGE | (a && a->dark ? FW_CAN_DARK : 0); }

float fw_dpi_scale(fw_app *a) { return a->scale > 0 ? a->scale : 1; }

void fw_set_title(fw_app *a, const char *title) {
    const char *t = title && *title ? title : "Forge";
    gtk_window_set_title(GTK_WINDOW(a->window), t);
    // "Bracket - Forge" → the document name in the header.
    char *doc = g_strdup(t);
    char *suffix = g_strrstr(doc, " - Forge");
    if (suffix && suffix != doc) *suffix = 0;
    gtk_label_set_text(GTK_LABEL(a->docTitle), doc);
    g_free(doc);
}

void fw_set_menu_check(fw_app *a, int id, int checked) {
    char name[16];
    snprintf(name, sizeof name, "m%d", id);
    GAction *act = g_action_map_lookup_action(G_ACTION_MAP(a->actions), name);
    if (act && g_action_get_state_type(act)) g_simple_action_set_state(G_SIMPLE_ACTION(act), g_variant_new_boolean(checked != 0));
}

void fw_set_menu_enabled(fw_app *a, int id, int enabled) {
    char name[16];
    snprintf(name, sizeof name, "m%d", id);
    GAction *act = g_action_map_lookup_action(G_ACTION_MAP(a->actions), name);
    if (act) g_simple_action_set_enabled(G_SIMPLE_ACTION(act), enabled != 0);
}

void fw_app_quit(fw_app *a) {
    if (a->window) gtk_window_close(GTK_WINDOW(a->window));
}
