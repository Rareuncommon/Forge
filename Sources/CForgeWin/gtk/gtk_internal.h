// Internal state of the Linux shell (GTK 4 + OpenGL), the same API as the Win32 shell
// (include/CForgeWin.h, docs/adr/0013-linux-app.md).

#pragma once

#include <gtk/gtk.h>

#include "../include/CForgeWin.h"

typedef struct fw_renderer fw_renderer;

typedef enum { PK_FIELD, PK_CHECK, PK_CHOICE, PK_LIST, PK_NOTE, PK_VALUE, PK_BUTTONS, PK_ROWS } PanelKind;

typedef struct {
    PanelKind kind;
    int section;
    GtkWidget *main;  // receives the value (entry, check, drop-down, list)
} PanelControl;

typedef struct {
    int toggle;       // -1 plain, 0 / 1 check group
    char *title;
} PanelSection;

struct fw_app {
    GtkWidget *window, *header, *docTitle, *docSubtitle, *tabs[3], *ribbon, *filter, *tree, *panel, *panelBox, *view, *overlay;
    GtkWidget *status[3], *statusCells[3];
    GtkWidget *modify, *modifyLabel, *modifyEntry;
    GtkWidget *corner, *cornerOK, *cornerCancel, *badge, *badgeIcon, *badgeTitle, *badgeDetail;
    GSimpleActionGroup *actions;
    fw_handler handler;
    void *ctx;
    int quit;
    int building;          // suppress change notifications while controls are built or set
    int dark;              // dark appearance
    int cornerMode;
    char *ribbonKey, *treeKey;

    // Ribbon being described (between fw_ribbon_begin / end).
    GPtrArray *pendingGroups;   // char *
    GArray *pendingItems;       // RibbonItem

    // Tree being described (built in fw_tree_end); collapsed node titles.
    GArray *nodes;              // TreeNode
    GHashTable *collapsed;

    // PropertyManager.
    GArray *controls;           // PanelControl
    GArray *sections;           // PanelSection
    GtkWidget *sectionBox;      // where controls of the current section go
    GHashTable *closedSections; // section titles the user collapsed

    fw_renderer *renderer;
    int viewWidth, viewHeight;  // framebuffer pixels
    float scale;                // framebuffer pixels per logical pixel
};

void fw_emit(fw_app *a, fw_event e);
fw_event fw_event_make(int kind, int id, int sub);

// Icons (gtk_icons.c)
GtkWidget *fw_icon_widget(const char *name, int size);
void fw_icon_widget_set_white(GtkWidget *icon);
void fw_icon_draw(cairo_t *cr, const char *name, double size, GdkRGBA ink, gboolean sensitive);
void fw_icons_set_accent(GdkRGBA c);
gboolean fw_icon_exists(const char *name);

// Renderer (gtk_render.c)
fw_renderer *fw_renderer_create(void);
void fw_renderer_destroy(fw_renderer *);
void fw_render_realize(fw_app *a);
void fw_render_unrealize(fw_app *a);
GtkWidget *fw_render_create_view(fw_app *a);
