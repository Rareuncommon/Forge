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
} PanelSection;

struct fw_app {
    GtkWidget *window, *menubar, *tabs[3], *ribbon, *filter, *tree, *panel, *panelBox, *view, *overlay;
    GtkWidget *status[3];
    GtkWidget *modify, *modifyLabel, *modifyEntry;
    GSimpleActionGroup *actions;
    fw_handler handler;
    void *ctx;
    int quit;
    int building;          // suppress change notifications while controls are built or set
    char *ribbonKey, *treeKey;

    // Ribbon being described (between fw_ribbon_begin / end).
    GPtrArray *pendingGroups;   // char *
    GArray *pendingItems;       // RibbonItem
    int itemCount;

    // Tree being described.
    GString *pendingTree;
    GArray *nodes;              // TreeNode
    GString *treeBuild;

    // PropertyManager.
    GArray *controls;           // PanelControl
    GArray *sections;           // PanelSection
    GtkWidget *sectionBox;      // where controls of the current section go
    int sectionOn;

    fw_renderer *renderer;
    int viewWidth, viewHeight;  // framebuffer pixels
    float scale;                // framebuffer pixels per logical pixel
};

void fw_emit(fw_app *a, fw_event e);
fw_event fw_event_make(int kind, int id, int sub);

// Renderer (gtk_render.c)
fw_renderer *fw_renderer_create(void);
void fw_renderer_destroy(fw_renderer *);
void fw_render_realize(fw_app *a);
void fw_render_unrealize(fw_app *a);
