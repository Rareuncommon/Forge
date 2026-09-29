// Exercise the real native menu model and action group, without opening file dialogs.
#include "gtk_internal.h"
#include <stdio.h>
#include <string.h>

typedef struct {
    int importItems;
    int actions;
    int failures;
    int importEvents;
} TestState;

static void receive(void *context, const fw_event *event) {
    TestState *state = context;
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
    fw_app_destroy(app);
    if (state.failures) return 1;
    printf("GTK menu actions: %d registered entries; Import STEP dispatch passed\n", state.actions);
    return 0;
}
