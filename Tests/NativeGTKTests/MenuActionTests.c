// Exercise the real native menu/action group and name-entry dialog without Swift.
#include "gtk_internal.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
    int zoomItems;
    int zoomEvents;
    int importItems;
    int actions;
    int failures;
    int importEvents;
} TestState;

static void receive(void *context, const fw_event *event) {
    TestState *state = context;
    if (event->kind == FW_EV_MENU && event->id == FW_MENU_ZOOM_SELECTION) ++state->zoomEvents;
    if (event->kind == FW_EV_MENU && event->id == FW_MENU_IMPORT_STEP) ++state->importEvents;
}

static void checkMenu(fw_app *app, GMenuModel *menu, TestState *state) {
    for (int index = 0; index < g_menu_model_get_n_items(menu); ++index) {
        char *action = NULL;
        if (g_menu_model_get_item_attribute(menu, index, G_MENU_ATTRIBUTE_ACTION, "s", &action)) {
            ++state->actions;
            if (!g_str_has_prefix(action, "win.") || !g_action_group_has_action(G_ACTION_GROUP(app->actions), action + 4)) {
                fprintf(stderr, "Menu references unregistered action: %s\n", action);
                ++state->failures;
            }
            char expected[32];
            snprintf(expected, sizeof expected, "win.m%d", FW_MENU_IMPORT_STEP);
            if (strcmp(action, expected) == 0) {
                ++state->importItems;
                // Resolve through the widget's installed action group, like a menu click.
                if (!gtk_widget_activate_action(app->window, action, NULL)) {
                    fprintf(stderr, "Import STEP menu action could not be activated\n");
                    ++state->failures;
                }
            }
            snprintf(expected, sizeof expected, "win.m%d", FW_MENU_ZOOM_SELECTION);
            if (strcmp(action, expected) == 0) {
                ++state->zoomItems;
                if (!gtk_widget_activate_action(app->window, action, NULL)) {
                    fprintf(stderr, "Zoom to Selection menu action could not be activated\n");
                    ++state->failures;
                }
            }
            g_free(action);
        }
        const char *links[] = {G_MENU_LINK_SECTION, G_MENU_LINK_SUBMENU};
        for (size_t link = 0; link < G_N_ELEMENTS(links); ++link) {
            GMenuModel *child = g_menu_model_get_item_link(menu, index, links[link]);
            if (child) {
                checkMenu(app, child, state);
                g_object_unref(child);
            }
        }
    }
}

static void checkWidgets(fw_app *app, GtkWidget *widget, TestState *state) {
    if (GTK_IS_MENU_BUTTON(widget)) {
        GMenuModel *menu = gtk_menu_button_get_menu_model(GTK_MENU_BUTTON(widget));
        if (menu) checkMenu(app, menu, state);
    }
    for (GtkWidget *child = gtk_widget_get_first_child(widget); child; child = gtk_widget_get_next_sibling(child)) {
        checkWidgets(app, child, state);
    }
}

typedef struct {
    TestState *state;
    const char *title;
    const char *initial;
    const char *replacement;
    int response;
    int responded;
    gint64 deadline;
} NameResponse;

static GtkWidget *findEntry(GtkWidget *widget) {
    if (GTK_IS_ENTRY(widget)) return widget;
    for (GtkWidget *child = gtk_widget_get_first_child(widget); child; child = gtk_widget_get_next_sibling(child)) {
        GtkWidget *entry = findEntry(child);
        if (entry) return entry;
    }
    return NULL;
}

// fw_name_dialog runs GTK's nested main loop. Drive its actual widgets from that loop,
// rather than replacing the dialog function with a mock. Both this deadline and the
// shell timeout prevent a broken response connection from hanging CI indefinitely.
static gboolean respondToName(gpointer data) {
    NameResponse *response = data;
    if (g_get_monotonic_time() >= response->deadline) {
        fprintf(stderr, "Timed out waiting for name dialog: %s\n", response->title);
        exit(1);
    }
    GListModel *windows = gtk_window_get_toplevels();
    for (guint i = 0; i < g_list_model_get_n_items(windows); ++i) {
        GtkWindow *window = g_list_model_get_item(windows, i);
        if (GTK_IS_DIALOG(window) && g_strcmp0(gtk_window_get_title(window), response->title) == 0) {
            GtkWidget *entry = findEntry(GTK_WIDGET(window));
            if (!entry) {
                fprintf(stderr, "Name dialog has no editable entry\n");
                ++response->state->failures;
            } else {
                if (strcmp(gtk_editable_get_text(GTK_EDITABLE(entry)), response->initial) != 0) {
                    fprintf(stderr, "Name dialog did not preserve initial UTF-8 text\n");
                    ++response->state->failures;
                }
                gtk_editable_set_text(GTK_EDITABLE(entry), response->replacement);
            }
            response->responded = 1;
            gtk_dialog_response(GTK_DIALOG(window), response->response);
            g_object_unref(window);
            return G_SOURCE_REMOVE;
        }
        g_object_unref(window);
    }
    return G_SOURCE_CONTINUE;
}

static void checkNameDialog(fw_app *app, TestState *state, int action, const char *text) {
    NameResponse response = {state, "Rename regression", "Original — 部品", text, action, 0,
                             g_get_monotonic_time() + 5 * G_TIME_SPAN_SECOND};
    guint source = g_timeout_add(10, respondToName, &response);
    char *name = fw_name_dialog(app, response.title, response.initial);
    if (!response.responded) {
        g_source_remove(source);
        fprintf(stderr, "Name dialog returned before a response\n");
        ++state->failures;
    }
    if (action == GTK_RESPONSE_ACCEPT) {
        if (!name || strcmp(name, text) != 0) {
            fprintf(stderr, "Name dialog did not return exact accepted UTF-8 text\n");
            ++state->failures;
        }
    } else if (name != NULL) {
        fprintf(stderr, "Cancelled name dialog returned a value\n");
        ++state->failures;
    }
    fw_free(name); // Includes the cancellation path: freeing NULL must be harmless.
}

int main(void) {
    TestState state = {0};
    fw_app *app = fw_app_create("Menu action regression", receive, &state);
    if (!app) {
        fprintf(stderr, "Could not create GTK application; run this test under Xvfb\n");
        return 1;
    }
    checkWidgets(app, app->window, &state);
    if (state.actions == 0 || state.importItems != 1 || state.importEvents != 1) {
        fprintf(stderr, "Expected one Import STEP item/event; found %d actions, %d items, %d events\n",
                state.actions, state.importItems, state.importEvents);
        ++state.failures;
    }
    if (state.zoomItems != 1 || state.zoomEvents != 1) {
        fprintf(stderr, "Expected one Zoom to Selection item/event; found %d items, %d events\n", state.zoomItems, state.zoomEvents);
        ++state.failures;
    }
    checkNameDialog(app, &state, GTK_RESPONSE_ACCEPT, "机架 — café 🚀");
    checkNameDialog(app, &state, GTK_RESPONSE_CANCEL, "discarded replacement");
    checkNameDialog(app, &state, GTK_RESPONSE_ACCEPT, "");
    fw_app_destroy(app);
    if (state.failures) return 1;
    printf("GTK menu actions: %d registered entries; Import STEP dispatch passed\n", state.actions);
    printf("GTK name dialog: UTF-8 accept, cancellation and empty input passed\n");
    return 0;
}
