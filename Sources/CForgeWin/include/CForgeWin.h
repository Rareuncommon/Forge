// Native Windows shell of Forge (docs/adr/0012-windows-app.md): the Win32 window with its
// ribbon, FeatureManager tree, PropertyManager, status bar and dialogs, and the Direct3D 11
// viewport renderer, behind a plain C API. The Swift front end (Sources/ForgeWin) describes
// what to show (from ForgeUI's shared specs) and receives input as events; it owns no Win32
// code. Strings are UTF-8.

#ifndef CFORGEWIN_H
#define CFORGEWIN_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct fw_app fw_app;
typedef struct fw_buffer fw_buffer;

/// Event kinds delivered to the handler.
enum {
    FW_EV_MENU = 1,             // id = FW_MENU_*
    FW_EV_TAB = 2,              // id = ribbon tab index
    FW_EV_RIBBON = 3,           // id = button index, sub = variant index or -1 (the button itself)
    FW_EV_TREE_SELECT = 4,      // id = node index (build order)
    FW_EV_TREE_ACTIVATE = 5,    // id = node index (double-click)
    FW_EV_TREE_MENU = 6,        // id = node index, sub = menu item
    FW_EV_PANEL_TEXT = 7,       // id = control index, text = new value
    FW_EV_PANEL_SUBMIT = 8,     // id = control index (Return or focus leaves a field)
    FW_EV_PANEL_CHECK = 9,      // id = control index, sub = 0 / 1
    FW_EV_PANEL_CHOICE = 10,    // id = control index, sub = option index
    FW_EV_PANEL_BUTTON = 11,    // id = control index, sub = button index
    FW_EV_PANEL_ROW_DELETE = 12,// id = control index, sub = row
    FW_EV_PANEL_LIST = 13,      // id = control index (the list was clicked: make it receive picks)
    FW_EV_PANEL_SECTION = 14,   // id = section index, sub = 0 / 1 (check group toggled)
    FW_EV_PANEL_OK = 15,
    FW_EV_PANEL_CANCEL = 16,
    FW_EV_MOUSE_DOWN = 20,      // viewport: x, y, button, clicks, mods
    FW_EV_MOUSE_UP = 21,
    FW_EV_MOUSE_MOVE = 22,      // x, y, mods; button = pressed button or -1
    FW_EV_MOUSE_WHEEL = 23,     // x, y, wheel (notches, positive away from the user), mods
    FW_EV_MOUSE_LEAVE = 24,
    FW_EV_KEY = 25,             // viewport key: text = "a".."z" / "A".."Z" / "return" / "escape" / "delete" / "space"
    FW_EV_PAINT = 26,           // the viewport needs a frame
    FW_EV_RESIZE = 27,          // x, y = viewport size in pixels
    FW_EV_EDIT_COMMIT = 28,     // the Modify box: text = value
    FW_EV_EDIT_CANCEL = 29,
    FW_EV_FILTER = 30,          // tree filter text changed: text
    FW_EV_CLOSE = 31,           // the window is closing
    FW_EV_TICK = 32             // timer (about 30 Hz while the app runs)
};

enum { FW_MOD_SHIFT = 1, FW_MOD_CTRL = 2, FW_MOD_ALT = 4 };

/// Menu commands (FW_EV_MENU).
enum {
    FW_MENU_NEW = 100, FW_MENU_OPEN, FW_MENU_SAVE, FW_MENU_SAVE_AS, FW_MENU_EXPORT_STEP, FW_MENU_EXPORT_STL, FW_MENU_EXIT,
    FW_MENU_UNDO = 200, FW_MENU_REDO,
    FW_MENU_FRONT = 300, FW_MENU_BACK, FW_MENU_LEFT, FW_MENU_RIGHT, FW_MENU_TOP, FW_MENU_BOTTOM, FW_MENU_ISOMETRIC,
    FW_MENU_DIMETRIC, FW_MENU_TRIMETRIC, FW_MENU_NORMAL_TO, FW_MENU_FIT, FW_MENU_PREVIOUS,
    FW_MENU_PERSPECTIVE = 320, FW_MENU_PLANES, FW_MENU_RELATIONS, FW_MENU_DIMENSIONS,
    FW_MENU_SHADED_EDGES = 330, FW_MENU_SHADED, FW_MENU_WIREFRAME, FW_MENU_HIDDEN_LINES,
    FW_MENU_ABOUT = 400
};

/// Tree node states (fw_tree_node).
enum { FW_NODE_NORMAL = 0, FW_NODE_SUPPRESSED, FW_NODE_ROLLED_BACK, FW_NODE_WARNING, FW_NODE_ERROR, FW_NODE_ROLLBACK_BAR };

typedef struct {
    int kind, id, sub;
    int x, y;          // viewport pixels, origin top-left
    int button;        // 0 left, 1 right, 2 middle
    int clicks;
    int mods;          // FW_MOD_*
    float wheel;
    const char *text;  // UTF-8, valid during the call
} fw_event;

typedef void (*fw_handler)(void *ctx, const fw_event *e);

// MARK: application

/// Create the main window (hidden until fw_app_show). NULL on failure.
fw_app *fw_app_create(const char *title, fw_handler handler, void *ctx);
void fw_app_show(fw_app *);
/// Process window messages for up to `timeout_ms` (returns early on input). 0 once the
/// application has quit.
int fw_app_pump(fw_app *, int timeout_ms);
void fw_app_destroy(fw_app *);
/// Pixels per 96-dpi unit.
float fw_dpi_scale(fw_app *);
void fw_set_title(fw_app *, const char *title);
void fw_set_menu_check(fw_app *, int id, int checked);
void fw_set_menu_enabled(fw_app *, int id, int enabled);
void fw_set_status(fw_app *, const char *left, const char *middle, const char *right);
/// Select the ribbon tab (0 Features, 1 Sketch, 2 Evaluate) without an event.
void fw_set_tab(fw_app *, int index);

// MARK: ribbon (rebuilt as a whole)

void fw_ribbon_begin(fw_app *);
void fw_ribbon_group(fw_app *, const char *title);
/// `variants`: flyout items separated by '\n' ("" for none).
void fw_ribbon_button(fw_app *, const char *title, const char *help, int large, int active, int enabled, const char *variants);
void fw_ribbon_end(fw_app *);

// MARK: FeatureManager tree (rebuilt as a whole)

void fw_tree_begin(fw_app *);
/// `menu`: context menu items separated by '\n'.
void fw_tree_node(fw_app *, int depth, const char *title, const char *tooltip, int state, int selected, const char *menu);
void fw_tree_end(fw_app *);

// MARK: PropertyManager

/// Controls are numbered in the order they are added (sections are numbered separately).
void fw_panel_begin(fw_app *, const char *title, const char *subtitle, const char *message, int has_ok, int has_cancel);
/// `toggle`: -1 plain section, 0 / 1 check group (its controls only follow when on).
void fw_panel_section(fw_app *, const char *title, int toggle);
void fw_panel_field(fw_app *, const char *label, const char *unit, const char *value);
void fw_panel_check(fw_app *, const char *label, int value);
/// `options` separated by '\n'.
void fw_panel_choice(fw_app *, const char *label, const char *options, int selected);
void fw_panel_list(fw_app *, const char *items, const char *placeholder, int active);
void fw_panel_note(fw_app *, const char *text, int warning);
void fw_panel_value(fw_app *, const char *label, const char *value);
void fw_panel_buttons(fw_app *, const char *titles);
/// Rows (relations): `texts`, `details` and `problems` ("0"/"1") separated by '\n'.
void fw_panel_rows(fw_app *, const char *texts, const char *details, const char *problems, int deletable);
void fw_panel_end(fw_app *);
/// Update values without rebuilding. A field being edited keeps what the user typed.
void fw_panel_set_text(fw_app *, int control, const char *value);
void fw_panel_set_check(fw_app *, int control, int value);
void fw_panel_set_choice(fw_app *, int control, int index);

// MARK: Modify box (value entry over the viewport)

void fw_edit_show(fw_app *, int x, int y, const char *label, const char *value);
void fw_edit_hide(fw_app *);

// MARK: dialogs (returned strings are freed with fw_free)

int fw_confirm(fw_app *, const char *title, const char *message, const char *yes, const char *no);
char *fw_save_dialog(fw_app *, const char *suggested_name);
/// A .forgepart document (a folder).
char *fw_open_dialog(fw_app *);
void fw_message(fw_app *, const char *title, const char *message, int error);
void fw_free(void *);
/// Capture the main window's client area as RGBA8 rows (top row first); free with fw_free.
/// NULL on failure.
uint8_t *fw_capture(fw_app *, int *width, int *height);
/// Close the main window (as if the user did).
void fw_app_quit(fw_app *);

// MARK: viewport rendering (Direct3D 11; pipelines and depth modes as ForgeRender.ViewportPlan)

void fw_view_invalidate(fw_app *);
void fw_view_size(fw_app *, int *width, int *height);
/// Focus the viewport (keys go to it).
void fw_view_focus(fw_app *);
fw_buffer *fw_buffer_create(fw_app *, const void *bytes, int length);
void fw_buffer_release(fw_buffer *);
/// Start a frame: clears to a vertical gradient (RGBA 0–1). 0 when there is no device.
int fw_frame_begin(fw_app *, const float top[4], const float bottom[4]);
/// pipeline: 0 shaded, 1 lines, 2 preview, 3 pick triangles, 4 pick lines; depth: 0 write,
/// 1 test only, 2 none. `uniforms`: 36 floats.
void fw_draw(fw_app *, int pipeline, int depth, fw_buffer *, int vertex_count, const float *uniforms);
/// 2D overlay (Direct2D) after the 3D draws of a frame. rgba = 0xRRGGBBAA.
/// align: 0 left, 1 centre; boxed: draw on a rounded label background.
void fw_text(fw_app *, const char *text, float x, float y, float size, uint32_t rgba, int align, int boxed);
void fw_line2d(fw_app *, float x0, float y0, float x1, float y1, float width, uint32_t rgba);
void fw_frame_end(fw_app *);
/// Pick pass: fw_draw the pick draws between these; reads the w×h region at (x0, y0) of the
/// object and element targets. 0 on failure.
int fw_pick_begin(fw_app *);
int fw_pick_end(fw_app *, int x0, int y0, int w, int h, uint32_t *objects, uint32_t *elements);

#ifdef __cplusplus
}
#endif

#endif
