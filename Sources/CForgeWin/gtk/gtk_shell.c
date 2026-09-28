// Linux shell of Forge (docs/adr/0013-linux-app.md): the GTK 4 window with its menus, ribbon,
// FeatureManager tree, PropertyManager, status bar, Modify box and dialogs, behind the same C
// API as the Win32 shell (include/CForgeWin.h), so the Swift front end (Sources/ForgeWin) runs
// unchanged. Layout and colours follow the Windows and macOS apps: ribbon on top, tree on the
// left, viewport in the middle, PropertyManager on the right. The viewport is gtk_render.c.

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

// MARK: style (the design's light theme, as on Windows)

static const char *kCSS =
    "window.forge { background: #E9E9EC; color: #1D1D1F; }\n"
    ".forge-tabs { background: #E9E9EC; padding: 2px 8px 0 8px; }\n"
    ".forge-tab { border-radius: 6px 6px 0 0; padding: 3px 14px; background: transparent; border: none; box-shadow: none; color: #5E5E66; }\n"
    ".forge-tab.active { background: #FBFBFC; color: #1D1D1F; font-weight: 600; }\n"
    ".forge-ribbon { background: #FBFBFC; border-bottom: 1px solid #D5D5DA; padding: 4px 6px; }\n"
    ".forge-group { border-right: 1px solid #D5D5DA; padding: 0 6px; }\n"
    ".forge-group-title { color: #8A8A91; font-size: 9pt; }\n"
    ".forge-rb { padding: 2px 6px; min-height: 0; border: 1px solid transparent; background: transparent; box-shadow: none; color: #1D1D1F; }\n"
    ".forge-rb:hover { background: #EDEDF0; }\n"
    ".forge-rb.active { background: #E1EAFB; border-color: #1F5FD6; color: #1A4FB3; }\n"
    ".forge-rb.large { min-width: 70px; min-height: 58px; }\n"
    ".forge-side { background: #FBFBFC; }\n"
    ".forge-left { border-right: 1px solid #D5D5DA; }\n"
    ".forge-right { border-left: 1px solid #D5D5DA; }\n"
    ".forge-tree row { padding: 1px 4px; }\n"
    ".forge-node.selected { background: #E1EAFB; color: #1A4FB3; border-radius: 4px; }\n"
    ".forge-node.dim { color: #8A8A91; }\n"
    ".forge-node.warning { color: #B45309; }\n"
    ".forge-node.error { color: #C82E21; }\n"
    ".forge-node.rollback { color: #1F5FD6; font-weight: 600; }\n"
    ".forge-bar { background: #1F5FD6; min-height: 3px; }\n"
    ".forge-title { font-size: 14pt; font-weight: 600; }\n"
    ".forge-subtitle { color: #5E5E66; font-size: 9pt; }\n"
    ".forge-message { background: #FFF4CE; border-radius: 6px; padding: 8px; }\n"
    ".forge-section { font-weight: 600; margin-top: 6px; }\n"
    ".forge-note { color: #5E5E66; font-size: 9pt; }\n"
    ".forge-note.warning { color: #B45309; }\n"
    ".forge-unit { color: #8A8A91; font-size: 9pt; }\n"
    ".forge-list { border: 1px solid #D5D5DA; border-radius: 4px; background: white; padding: 4px 6px; }\n"
    ".forge-list.active { border-color: #1F5FD6; background: #F3F7FE; }\n"
    ".forge-placeholder { color: #8A8A91; }\n"
    ".forge-problem { color: #C82E21; }\n"
    ".forge-status { background: #E9E9EC; border-top: 1px solid #D5D5DA; padding: 2px 10px; color: #5E5E66; font-size: 9pt; }\n"
    ".forge-modify { background: #FBFBFC; border: 1px solid #D5D5DA; border-radius: 6px; padding: 6px; }\n";

static void loadCSS(void) {
    GtkCssProvider *p = gtk_css_provider_new();
#if GTK_CHECK_VERSION(4, 12, 0)
    gtk_css_provider_load_from_string(p, kCSS);
#else
    gtk_css_provider_load_from_data(p, kCSS, -1);
#endif
    gtk_style_context_add_provider_for_display(gdk_display_get_default(), GTK_STYLE_PROVIDER(p), GTK_STYLE_PROVIDER_PRIORITY_APPLICATION);
    g_object_unref(p);
}

// MARK: menus

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

static GtkWidget *buildMenus(fw_app *a) {
    a->actions = g_simple_action_group_new();
    for (int id = FW_MENU_NEW; id <= FW_MENU_EXIT; ++id) addAction(a, id, 0);
    addAction(a, FW_MENU_UNDO, 0);
    addAction(a, FW_MENU_REDO, 0);
    for (int id = FW_MENU_FRONT; id <= FW_MENU_PREVIOUS; ++id) addAction(a, id, 0);
    for (int id = FW_MENU_PERSPECTIVE; id <= FW_MENU_DIMENSIONS; ++id) addAction(a, id, 1);
    for (int id = FW_MENU_SHADED_EDGES; id <= FW_MENU_HIDDEN_LINES; ++id) addAction(a, id, 1);
    addAction(a, FW_MENU_ABOUT, 0);
    gtk_widget_insert_action_group(a->window, "win", G_ACTION_GROUP(a->actions));

    GMenu *bar = g_menu_new(), *file = g_menu_new(), *edit = g_menu_new(), *view = g_menu_new(), *help = g_menu_new();
    GMenu *f1 = g_menu_new(), *f2 = g_menu_new(), *f3 = g_menu_new();
    item(f1, "_New Part", FW_MENU_NEW);
    item(f1, "_Open…", FW_MENU_OPEN);
    item(f1, "_Save", FW_MENU_SAVE);
    item(f1, "Save _As…", FW_MENU_SAVE_AS);
    item(f2, "Export _STEP…", FW_MENU_EXPORT_STEP);
    item(f2, "Export ST_L…", FW_MENU_EXPORT_STL);
    item(f3, "_Quit", FW_MENU_EXIT);
    g_menu_append_section(file, NULL, G_MENU_MODEL(f1));
    g_menu_append_section(file, NULL, G_MENU_MODEL(f2));
    g_menu_append_section(file, NULL, G_MENU_MODEL(f3));
    item(edit, "_Undo", FW_MENU_UNDO);
    item(edit, "_Redo", FW_MENU_REDO);

    GMenu *orient = g_menu_new(), *display = g_menu_new(), *v1 = g_menu_new(), *v2 = g_menu_new(), *v3 = g_menu_new();
    const char *names[] = {"_Front", "_Back", "_Left", "_Right", "_Top", "B_ottom", "_Isometric", "_Dimetric", "T_rimetric", "_Normal To"};
    for (int i = 0; i < 10; ++i) item(orient, names[i], FW_MENU_FRONT + i);
    item(display, "Shaded With _Edges", FW_MENU_SHADED_EDGES);
    item(display, "_Shaded", FW_MENU_SHADED);
    item(display, "_Wireframe", FW_MENU_WIREFRAME);
    item(display, "_Hidden Lines Removed", FW_MENU_HIDDEN_LINES);
    g_menu_append_submenu(v1, "_Orientation", G_MENU_MODEL(orient));
    item(v1, "Zoom to _Fit", FW_MENU_FIT);
    item(v1, "_Previous View", FW_MENU_PREVIOUS);
    g_menu_append_submenu(v2, "_Display Style", G_MENU_MODEL(display));
    item(v2, "P_erspective", FW_MENU_PERSPECTIVE);
    item(v3, "Pla_nes", FW_MENU_PLANES);
    item(v3, "Sketch _Relations", FW_MENU_RELATIONS);
    item(v3, "Sketch Di_mensions", FW_MENU_DIMENSIONS);
    g_menu_append_section(view, NULL, G_MENU_MODEL(v1));
    g_menu_append_section(view, NULL, G_MENU_MODEL(v2));
    g_menu_append_section(view, NULL, G_MENU_MODEL(v3));
    item(help, "_About Forge", FW_MENU_ABOUT);
    g_menu_append_submenu(bar, "_File", G_MENU_MODEL(file));
    g_menu_append_submenu(bar, "_Edit", G_MENU_MODEL(edit));
    g_menu_append_submenu(bar, "_View", G_MENU_MODEL(view));
    g_menu_append_submenu(bar, "_Help", G_MENU_MODEL(help));
    GtkWidget *w = gtk_popover_menu_bar_new_from_model(G_MENU_MODEL(bar));

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

    GObject *objs[] = {G_OBJECT(bar), G_OBJECT(file), G_OBJECT(edit), G_OBJECT(view), G_OBJECT(help), G_OBJECT(f1), G_OBJECT(f2), G_OBJECT(f3),
                       G_OBJECT(orient), G_OBJECT(display), G_OBJECT(v1), G_OBJECT(v2), G_OBJECT(v3)};
    for (size_t i = 0; i < sizeof objs / sizeof objs[0]; ++i) g_object_unref(objs[i]);
    return w;
}

// MARK: ribbon

typedef struct {
    char *title, *help, *variants;
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

/// The ribbon button for `it`, with a ▾ flyout for its variants.
static GtkWidget *ribbonButton(fw_app *a, const RibbonItem *it, int index) {
    GtkWidget *row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    char *text = g_strdup(it->title);
    if (it->large) {
        // Two lines: break at the space nearest the middle.
        size_t n = strlen(text), best = 0;
        for (size_t i = 0; i < n; ++i)
            if (text[i] == ' ' && (best == 0 || labs((long)i - (long)n / 2) < labs((long)best - (long)n / 2))) best = i;
        if (best > 0) text[best] = '\n';
    }
    GtkWidget *b = gtk_button_new();
    GtkWidget *l = gtk_label_new(text);
    gtk_label_set_justify(GTK_LABEL(l), it->large ? GTK_JUSTIFY_CENTER : GTK_JUSTIFY_LEFT);
    gtk_label_set_xalign(GTK_LABEL(l), it->large ? 0.5f : 0.0f);
    gtk_button_set_child(GTK_BUTTON(b), l);
    g_free(text);
    gtk_widget_add_css_class(b, "forge-rb");
    if (it->large) gtk_widget_add_css_class(b, "large");
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
        gtk_widget_add_css_class(menu, "forge-rb");
        gtk_widget_set_sensitive(menu, it->enabled);
        GtkWidget *pop = gtk_popover_new(), *list = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2);
        for (int k = 0; variants[k]; ++k) {
            GtkWidget *v = gtk_button_new_with_label(variants[k]);
            gtk_button_set_has_frame(GTK_BUTTON(v), FALSE);
            g_object_set_data(G_OBJECT(v), "forge-id", GINT_TO_POINTER(index));
            g_object_set_data(G_OBJECT(v), "forge-sub", GINT_TO_POINTER(k + 1));
            g_signal_connect(v, "clicked", G_CALLBACK(onRibbon), a);
            gtk_box_append(GTK_BOX(list), v);
        }
        gtk_popover_set_child(GTK_POPOVER(pop), list);
        gtk_menu_button_set_popover(GTK_MENU_BUTTON(menu), pop);
        gtk_box_append(GTK_BOX(row), menu);
    }
    g_strfreev(variants);
    return row;
}

static void freeRibbonItems(fw_app *a) {
    for (guint i = 0; i < a->pendingItems->len; ++i) {
        RibbonItem *it = &g_array_index(a->pendingItems, RibbonItem, i);
        g_free(it->title);
        g_free(it->help);
        g_free(it->variants);
    }
    g_array_set_size(a->pendingItems, 0);
    g_ptr_array_set_size(a->pendingGroups, 0);
}

void fw_ribbon_begin(fw_app *a) { freeRibbonItems(a); }

void fw_ribbon_group(fw_app *a, const char *title) { g_ptr_array_add(a->pendingGroups, g_strdup(title)); }

void fw_ribbon_button(fw_app *a, const char *title, const char *help, int large, int active, int enabled, const char *variants) {
    RibbonItem it = {g_strdup(title), g_strdup(help), g_strdup(variants), large, active, enabled, (int)a->pendingGroups->len - 1};
    g_array_append_val(a->pendingItems, it);
}

void fw_ribbon_end(fw_app *a) {
    // Rebuild only when something shown changed (the front end pushes on every model change).
    GString *key = g_string_new(NULL);
    for (guint g = 0; g < a->pendingGroups->len; ++g) g_string_append_printf(key, "[%s]", (char *)g_ptr_array_index(a->pendingGroups, g));
    for (guint i = 0; i < a->pendingItems->len; ++i) {
        RibbonItem *it = &g_array_index(a->pendingItems, RibbonItem, i);
        g_string_append_printf(key, "%d|%s|%s|%d%d%d|%s;", it->group, it->title, it->help, it->large, it->active, it->enabled, it->variants);
    }
    if (a->ribbonKey && strcmp(a->ribbonKey, key->str) == 0) {
        g_string_free(key, TRUE);
        return;
    }
    g_free(a->ribbonKey);
    a->ribbonKey = g_string_free(key, FALSE);
    clearBox(a->ribbon);
    GtkWidget *groupBox = NULL, *row = NULL, *column = NULL;
    int group = -2, inColumn = 0;
    for (guint i = 0; i < a->pendingItems->len; ++i) {
        RibbonItem *it = &g_array_index(a->pendingItems, RibbonItem, i);
        if (it->group != group) {
            group = it->group;
            GtkWidget *outer = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2);
            gtk_widget_add_css_class(outer, "forge-group");
            row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 2);
            gtk_widget_set_valign(row, GTK_ALIGN_START);
            gtk_box_append(GTK_BOX(outer), row);
            const char *title = group >= 0 && (guint)group < a->pendingGroups->len ? g_ptr_array_index(a->pendingGroups, group) : "";
            GtkWidget *t = label(title, "forge-group-title");
            gtk_label_set_xalign(GTK_LABEL(t), 0.5f);
            gtk_box_append(GTK_BOX(outer), t);
            gtk_box_append(GTK_BOX(a->ribbon), outer);
            groupBox = outer;
            column = NULL;
            inColumn = 0;
        }
        (void)groupBox;
        GtkWidget *b = ribbonButton(a, it, (int)i);
        if (it->large) {
            column = NULL;
            gtk_box_append(GTK_BOX(row), b);
        } else {
            // Small buttons stack three to a column.
            if (!column || inColumn == 3) {
                column = gtk_box_new(GTK_ORIENTATION_VERTICAL, 1);
                gtk_box_append(GTK_BOX(row), column);
                inColumn = 0;
            }
            gtk_box_append(GTK_BOX(column), b);
            ++inColumn;
        }
    }
}

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

// MARK: tree

typedef struct {
    int state, selected;
    char *menu;
} TreeNode;

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
    (void)x;
    (void)y;
    fw_app *a = data;
    GtkWidget *w = gtk_event_controller_get_widget(GTK_EVENT_CONTROLLER(g));
    int node = GPOINTER_TO_INT(g_object_get_data(G_OBJECT(w), "forge-node"));
    guint button = gtk_gesture_single_get_current_button(GTK_GESTURE_SINGLE(g));
    if (button == GDK_BUTTON_SECONDARY) {
        if (node < 0 || (guint)node >= a->nodes->len) return;
        TreeNode *tn = &g_array_index(a->nodes, TreeNode, node);
        char **items = splitLines(tn->menu);
        if (items[0]) {
            GtkWidget *pop = gtk_popover_new(), *list = gtk_box_new(GTK_ORIENTATION_VERTICAL, 1);
            for (int k = 0; items[k]; ++k) {
                if (!strcmp(items[k], "Delete") || !strcmp(items[k], "What's Wrong?")) gtk_box_append(GTK_BOX(list), gtk_separator_new(GTK_ORIENTATION_HORIZONTAL));
                GtkWidget *b = gtk_button_new_with_label(items[k]);
                gtk_button_set_has_frame(GTK_BUTTON(b), FALSE);
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

static void freeNodes(GArray *nodes) {
    for (guint i = 0; i < nodes->len; ++i) g_free(g_array_index(nodes, TreeNode, i).menu);
    g_array_set_size(nodes, 0);
}

void fw_tree_begin(fw_app *a) {
    g_string_truncate(a->treeBuild, 0);
    freeNodes(a->nodes);
    clearBox(a->tree);  // rebuilt below only when the key changed; see fw_tree_end
}

void fw_tree_node(fw_app *a, int depth, const char *title, const char *tooltip, int state, int selected, const char *menu) {
    TreeNode n = {state, selected, g_strdup(menu)};
    g_array_append_val(a->nodes, n);
    int index = (int)a->nodes->len - 1;
    GtkWidget *row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    gtk_widget_add_css_class(row, "forge-node");
    gtk_widget_set_margin_start(row, 4 + 16 * (depth < 0 ? 0 : depth));
    GtkWidget *l = label(state == FW_NODE_ROLLBACK_BAR ? "Rollback" : title, NULL);
    gtk_label_set_ellipsize(GTK_LABEL(l), PANGO_ELLIPSIZE_END);
    gtk_box_append(GTK_BOX(row), l);
    switch (state) {
    case FW_NODE_SUPPRESSED:
    case FW_NODE_ROLLED_BACK: gtk_widget_add_css_class(row, "dim"); break;
    case FW_NODE_WARNING: gtk_widget_add_css_class(row, "warning"); break;
    case FW_NODE_ERROR: gtk_widget_add_css_class(row, "error"); break;
    case FW_NODE_ROLLBACK_BAR: {
        gtk_widget_add_css_class(row, "rollback");
        GtkWidget *bar = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
        gtk_widget_add_css_class(bar, "forge-bar");
        gtk_widget_set_hexpand(bar, TRUE);
        gtk_widget_set_valign(bar, GTK_ALIGN_CENTER);
        gtk_box_append(GTK_BOX(row), bar);
        break;
    }
    default: break;
    }
    if (selected) gtk_widget_add_css_class(row, "selected");
    if (tooltip && *tooltip) gtk_widget_set_tooltip_text(row, tooltip);
    g_object_set_data(G_OBJECT(row), "forge-node", GINT_TO_POINTER(index));
    GtkGesture *click = gtk_gesture_click_new();
    gtk_gesture_single_set_button(GTK_GESTURE_SINGLE(click), 0);
    g_signal_connect(click, "pressed", G_CALLBACK(onTreeClick), a);
    gtk_widget_add_controller(row, GTK_EVENT_CONTROLLER(click));
    gtk_list_box_append(GTK_LIST_BOX(a->tree), row);
}

void fw_tree_end(fw_app *a) { (void)a; }

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

void fw_panel_begin(fw_app *a, const char *title, const char *subtitle, const char *message, int has_ok, int has_cancel) {
    a->building = 1;
    clearBox(a->panelBox);
    g_array_set_size(a->controls, 0);
    g_array_set_size(a->sections, 0);
    GtkWidget *head = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    GtkWidget *t = label(title, "forge-title");
    gtk_widget_set_hexpand(t, TRUE);
    gtk_label_set_ellipsize(GTK_LABEL(t), PANGO_ELLIPSIZE_END);
    gtk_box_append(GTK_BOX(head), t);
    if (has_ok) {
        GtkWidget *ok = gtk_button_new_with_label("OK");
        gtk_widget_add_css_class(ok, "suggested-action");
        g_signal_connect(ok, "clicked", G_CALLBACK(onPanelOK), a);
        gtk_box_append(GTK_BOX(head), ok);
    }
    if (has_cancel) {
        GtkWidget *c = gtk_button_new_with_label("Cancel");
        g_signal_connect(c, "clicked", G_CALLBACK(onPanelCancel), a);
        gtk_box_append(GTK_BOX(head), c);
    }
    gtk_box_append(GTK_BOX(a->panelBox), head);
    if (subtitle && *subtitle) gtk_box_append(GTK_BOX(a->panelBox), label(subtitle, "forge-subtitle"));
    if (message && *message) {
        GtkWidget *m = label(message, "forge-message");
        gtk_label_set_wrap(GTK_LABEL(m), TRUE);
        gtk_widget_set_margin_top(m, 6);
        gtk_box_append(GTK_BOX(a->panelBox), m);
    }
    a->sectionBox = a->panelBox;
    a->sectionOn = 1;
}

void fw_panel_section(fw_app *a, const char *title, int toggle) {
    PanelSection s = {toggle};
    g_array_append_val(a->sections, s);
    int index = (int)a->sections->len - 1;
    if (toggle >= 0) {
        GtkWidget *c = gtk_check_button_new_with_label(title);
        gtk_widget_add_css_class(c, "forge-section");
        gtk_check_button_set_active(GTK_CHECK_BUTTON(c), toggle == 1);
        g_object_set_data(G_OBJECT(c), "forge-section", GINT_TO_POINTER(index));
        g_signal_connect(c, "toggled", G_CALLBACK(onSection), a);
        gtk_box_append(GTK_BOX(a->panelBox), c);
    } else if (title && *title) {
        gtk_box_append(GTK_BOX(a->panelBox), label(title, "forge-section"));
    }
    a->sectionBox = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
    gtk_widget_set_margin_start(a->sectionBox, 6);
    gtk_widget_set_visible(a->sectionBox, toggle != 0);
    gtk_box_append(GTK_BOX(a->panelBox), a->sectionBox);
}

static int addControl(fw_app *a, PanelKind kind, GtkWidget *main) {
    PanelControl c = {kind, (int)a->sections->len - 1, main};
    g_array_append_val(a->controls, c);
    int index = (int)a->controls->len - 1;
    if (main) g_object_set_data(G_OBJECT(main), "forge-control", GINT_TO_POINTER(index));
    return index;
}

/// A label on the left and `w` on the right (fields, choices, values).
static void labelled(fw_app *a, const char *text, GtkWidget *w, const char *unit) {
    GtkWidget *row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    GtkWidget *l = label(text, NULL);
    gtk_widget_set_size_request(l, 118, -1);
    gtk_label_set_ellipsize(GTK_LABEL(l), PANGO_ELLIPSIZE_END);
    gtk_box_append(GTK_BOX(row), l);
    gtk_widget_set_hexpand(w, TRUE);
    gtk_box_append(GTK_BOX(row), w);
    if (unit && *unit) {
        GtkWidget *u = label(unit, "forge-unit");
        gtk_widget_set_size_request(u, 30, -1);
        gtk_box_append(GTK_BOX(row), u);
    }
    gtk_box_append(GTK_BOX(a->sectionBox), row);
}

void fw_panel_field(fw_app *a, const char *label_, const char *unit, const char *value) {
    GtkWidget *e = gtk_entry_new();
    gtk_editable_set_text(GTK_EDITABLE(e), value ? value : "");
    gtk_editable_set_width_chars(GTK_EDITABLE(e), 6);
    addControl(a, PK_FIELD, e);
    g_signal_connect(e, "changed", G_CALLBACK(onFieldChanged), a);
    g_signal_connect(e, "activate", G_CALLBACK(onFieldActivate), a);
    GtkEventController *focus = gtk_event_controller_focus_new();
    g_signal_connect(focus, "leave", G_CALLBACK(onFieldLeave), a);
    gtk_widget_add_controller(e, focus);
    labelled(a, label_, e, unit);
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
    labelled(a, label_, d, NULL);
}

void fw_panel_list(fw_app *a, const char *items, const char *placeholder, int active) {
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 1);
    gtk_widget_add_css_class(box, "forge-list");
    if (active) gtk_widget_add_css_class(box, "active");
    char **lines = splitLines(items);
    if (!lines[0]) gtk_box_append(GTK_BOX(box), label(placeholder, "forge-placeholder"));
    for (int i = 0; lines[i]; ++i) gtk_box_append(GTK_BOX(box), label(lines[i], NULL));
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
    GtkWidget *v = label(value, NULL);
    gtk_label_set_selectable(GTK_LABEL(v), TRUE);
    gtk_label_set_ellipsize(GTK_LABEL(v), PANGO_ELLIPSIZE_END);
    addControl(a, PK_VALUE, v);
    labelled(a, label_, v, NULL);
}

void fw_panel_buttons(fw_app *a, const char *titles) {
    GtkWidget *flow = gtk_flow_box_new();
    gtk_flow_box_set_selection_mode(GTK_FLOW_BOX(flow), GTK_SELECTION_NONE);
    gtk_flow_box_set_max_children_per_line(GTK_FLOW_BOX(flow), 4);
    int index = addControl(a, PK_BUTTONS, flow);
    char **t = splitLines(titles);
    for (int k = 0; t[k]; ++k) {
        GtkWidget *b = gtk_button_new_with_label(t[k]);
        g_object_set_data(G_OBJECT(b), "forge-control", GINT_TO_POINTER(index));
        g_object_set_data(G_OBJECT(b), "forge-sub", GINT_TO_POINTER(k));
        g_signal_connect(b, "clicked", G_CALLBACK(onPanelButton), a);
        gtk_flow_box_append(GTK_FLOW_BOX(flow), b);
    }
    g_strfreev(t);
    gtk_box_append(GTK_BOX(a->sectionBox), flow);
}

void fw_panel_rows(fw_app *a, const char *texts, const char *details, const char *problems, int deletable) {
    GtkWidget *box = gtk_box_new(GTK_ORIENTATION_VERTICAL, 2);
    int index = addControl(a, PK_ROWS, box);
    char **t = splitLines(texts), **d = splitLines(details), **p = splitLines(problems);
    guint nd = g_strv_length(d), np = g_strv_length(p);
    for (guint k = 0; t[k]; ++k) {
        GtkWidget *row = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 4);
        GtkWidget *col = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
        gtk_widget_set_hexpand(col, TRUE);
        GtkWidget *l = label(t[k], k < np && !strcmp(p[k], "1") ? "forge-problem" : NULL);
        gtk_label_set_ellipsize(GTK_LABEL(l), PANGO_ELLIPSIZE_END);
        gtk_box_append(GTK_BOX(col), l);
        if (k < nd && *d[k]) gtk_box_append(GTK_BOX(col), label(d[k], "forge-note"));
        gtk_box_append(GTK_BOX(row), col);
        if (deletable) {
            GtkWidget *x = gtk_button_new_from_icon_name("window-close-symbolic");
            gtk_button_set_has_frame(GTK_BUTTON(x), FALSE);
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

void fw_panel_end(fw_app *a) { a->building = 0; }

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

// MARK: Modify box

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
    a->modify = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 6);
    gtk_widget_add_css_class(a->modify, "forge-modify");
    gtk_widget_set_halign(a->modify, GTK_ALIGN_START);
    gtk_widget_set_valign(a->modify, GTK_ALIGN_START);
    a->modifyLabel = label("", NULL);
    a->modifyEntry = gtk_entry_new();
    gtk_editable_set_width_chars(GTK_EDITABLE(a->modifyEntry), 10);
    g_signal_connect(a->modifyEntry, "activate", G_CALLBACK(onModifyCommit), a);
    GtkEventController *keys = gtk_event_controller_key_new();
    g_signal_connect(keys, "key-pressed", G_CALLBACK(onModifyKey), a);
    gtk_widget_add_controller(a->modifyEntry, keys);
    GtkWidget *ok = gtk_button_new_from_icon_name("object-select-symbolic"), *cancel = gtk_button_new_from_icon_name("window-close-symbolic");
    gtk_widget_set_tooltip_text(ok, "OK");
    gtk_widget_set_tooltip_text(cancel, "Cancel");
    g_signal_connect(ok, "clicked", G_CALLBACK(onModifyCommit), a);
    g_signal_connect(cancel, "clicked", G_CALLBACK(onModifyCancel), a);
    gtk_box_append(GTK_BOX(a->modify), a->modifyLabel);
    gtk_box_append(GTK_BOX(a->modify), a->modifyEntry);
    gtk_box_append(GTK_BOX(a->modify), ok);
    gtk_box_append(GTK_BOX(a->modify), cancel);
    gtk_widget_set_visible(a->modify, FALSE);
    return a->modify;
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
    GFile *f = r->button == 1 ? gtk_file_dialog_select_folder_finish(GTK_FILE_DIALOG(src), res, NULL) : gtk_file_dialog_save_finish(GTK_FILE_DIALOG(src), res, NULL);
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

GtkWidget *fw_render_create_view(fw_app *a);

fw_app *fw_app_create(const char *title, fw_handler handler, void *ctx) {
    if (!gtk_init_check()) return NULL;
    g_set_prgname("forge");
    g_set_application_name("Forge");
    // The panels use the design's light colours (as on Windows and macOS): pin GTK's own light
    // theme so a dark desktop theme does not put dark controls on them. GTK_THEME overrides.
    if (!g_getenv("GTK_THEME")) g_object_set(gtk_settings_get_default(), "gtk-theme-name", "Adwaita", "gtk-application-prefer-dark-theme", FALSE, NULL);
    loadCSS();
    fw_app *a = g_new0(fw_app, 1);
    a->handler = handler;
    a->ctx = ctx;
    a->scale = 1;
    a->pendingGroups = g_ptr_array_new_with_free_func(g_free);
    a->pendingItems = g_array_new(FALSE, TRUE, sizeof(RibbonItem));
    a->nodes = g_array_new(FALSE, TRUE, sizeof(TreeNode));
    a->treeBuild = g_string_new(NULL);
    a->controls = g_array_new(FALSE, TRUE, sizeof(PanelControl));
    a->sections = g_array_new(FALSE, TRUE, sizeof(PanelSection));
    a->renderer = fw_renderer_create();

    a->window = gtk_window_new();
    gtk_widget_add_css_class(a->window, "forge");
    gtk_window_set_title(GTK_WINDOW(a->window), title ? title : "Forge");
    gtk_window_set_icon_name(GTK_WINDOW(a->window), "forge");
    gtk_window_set_default_size(GTK_WINDOW(a->window), 1440, 900);
    g_signal_connect(a->window, "close-request", G_CALLBACK(onClose), a);
    g_signal_connect(a->window, "destroy", G_CALLBACK(onDestroy), a);

    GtkWidget *root = gtk_box_new(GTK_ORIENTATION_VERTICAL, 0);
    a->menubar = buildMenus(a);
    gtk_box_append(GTK_BOX(root), a->menubar);

    GtkWidget *tabs = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 2);
    gtk_widget_add_css_class(tabs, "forge-tabs");
    const char *names[] = {"Features", "Sketch", "Evaluate"};
    for (int i = 0; i < 3; ++i) {
        a->tabs[i] = gtk_button_new_with_label(names[i]);
        gtk_widget_add_css_class(a->tabs[i], "forge-tab");
        g_object_set_data(G_OBJECT(a->tabs[i]), "forge-id", GINT_TO_POINTER(i));
        g_signal_connect(a->tabs[i], "clicked", G_CALLBACK(onTab), a);
        gtk_box_append(GTK_BOX(tabs), a->tabs[i]);
    }
    fw_set_tab(a, 0);
    gtk_box_append(GTK_BOX(root), tabs);

    a->ribbon = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    GtkWidget *ribbonScroll = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(ribbonScroll), GTK_POLICY_AUTOMATIC, GTK_POLICY_NEVER);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(ribbonScroll), a->ribbon);
    gtk_widget_add_css_class(ribbonScroll, "forge-ribbon");
    gtk_widget_set_size_request(ribbonScroll, -1, 96);
    gtk_widget_set_vexpand(ribbonScroll, FALSE);
    gtk_box_append(GTK_BOX(root), ribbonScroll);

    GtkWidget *middle = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 0);
    gtk_widget_set_vexpand(middle, TRUE);

    GtkWidget *left = gtk_box_new(GTK_ORIENTATION_VERTICAL, 6);
    gtk_widget_add_css_class(left, "forge-side");
    gtk_widget_add_css_class(left, "forge-left");
    gtk_widget_set_size_request(left, 250, -1);
    gtk_widget_set_hexpand(left, FALSE);
    a->filter = gtk_search_entry_new();
    gtk_search_entry_set_placeholder_text(GTK_SEARCH_ENTRY(a->filter), "Filter features");
    gtk_widget_set_margin_start(a->filter, 6);
    gtk_widget_set_margin_end(a->filter, 6);
    gtk_widget_set_margin_top(a->filter, 6);
    g_signal_connect(a->filter, "search-changed", G_CALLBACK(onFilter), a);
    gtk_box_append(GTK_BOX(left), a->filter);
    a->tree = gtk_list_box_new();
    gtk_list_box_set_selection_mode(GTK_LIST_BOX(a->tree), GTK_SELECTION_NONE);
    gtk_widget_add_css_class(a->tree, "forge-tree");
    gtk_widget_add_css_class(a->tree, "forge-side");
    GtkWidget *treeScroll = gtk_scrolled_window_new();
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(treeScroll), a->tree);
    gtk_widget_set_vexpand(treeScroll, TRUE);
    gtk_box_append(GTK_BOX(left), treeScroll);
    gtk_box_append(GTK_BOX(middle), left);

    a->overlay = gtk_overlay_new();
    gtk_widget_set_hexpand(a->overlay, TRUE);
    a->view = fw_render_create_view(a);
    gtk_overlay_set_child(GTK_OVERLAY(a->overlay), a->view);
    gtk_overlay_add_overlay(GTK_OVERLAY(a->overlay), buildModify(a));
    gtk_box_append(GTK_BOX(middle), a->overlay);

    a->panelBox = gtk_box_new(GTK_ORIENTATION_VERTICAL, 4);
    gtk_widget_set_margin_start(a->panelBox, 14);
    gtk_widget_set_margin_end(a->panelBox, 14);
    gtk_widget_set_margin_top(a->panelBox, 12);
    gtk_widget_set_margin_bottom(a->panelBox, 12);
    a->panel = gtk_scrolled_window_new();
    gtk_scrolled_window_set_policy(GTK_SCROLLED_WINDOW(a->panel), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC);
    gtk_scrolled_window_set_child(GTK_SCROLLED_WINDOW(a->panel), a->panelBox);
    gtk_widget_add_css_class(a->panel, "forge-side");
    gtk_widget_add_css_class(a->panel, "forge-right");
    gtk_widget_set_size_request(a->panel, 320, -1);
    gtk_widget_set_hexpand(a->panel, FALSE);  // its entries expand within it, not into the viewport
    gtk_box_append(GTK_BOX(middle), a->panel);
    gtk_box_append(GTK_BOX(root), middle);

    GtkWidget *status = gtk_box_new(GTK_ORIENTATION_HORIZONTAL, 12);
    gtk_widget_add_css_class(status, "forge-status");
    for (int i = 0; i < 3; ++i) {
        a->status[i] = label("", NULL);
        gtk_label_set_ellipsize(GTK_LABEL(a->status[i]), PANGO_ELLIPSIZE_END);
        if (i == 0) gtk_widget_set_hexpand(a->status[i], TRUE);
        gtk_box_append(GTK_BOX(status), a->status[i]);
    }
    gtk_box_append(GTK_BOX(root), status);

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
    g_string_free(a->treeBuild, TRUE);
    g_array_unref(a->controls);
    g_array_unref(a->sections);
    g_clear_object(&a->actions);
    g_free(a->ribbonKey);
    g_free(a->treeKey);
    g_free(a);
}

float fw_dpi_scale(fw_app *a) { return a->scale > 0 ? a->scale : 1; }

void fw_set_title(fw_app *a, const char *title) { gtk_window_set_title(GTK_WINDOW(a->window), title ? title : "Forge"); }

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

void fw_set_status(fw_app *a, const char *left, const char *middle, const char *right) {
    gtk_label_set_text(GTK_LABEL(a->status[0]), left ? left : "");
    gtk_label_set_text(GTK_LABEL(a->status[1]), middle ? middle : "");
    gtk_label_set_text(GTK_LABEL(a->status[2]), right ? right : "");
}

void fw_app_quit(fw_app *a) {
    if (a->window) gtk_window_close(GTK_WINDOW(a->window));
}
