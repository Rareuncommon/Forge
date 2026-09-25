// Headless build of the Windows shell API: lets ForgeWin compile and link off Windows
// (FORGE_WIN_CHECK=1 swift build --product ForgeWin) so CI type-checks it on Linux. It opens
// no window: fw_app_create returns an app whose pump quits at once. Not used on Windows.

#include "CForgeWin.h"

#include <stdlib.h>

struct fw_app { int unused; };
struct fw_buffer { int unused; };
static struct fw_app headless_app;

fw_app * fw_app_create(const char *title, fw_handler handler, void *ctx) { (void)title; (void)handler; (void)ctx; return &headless_app; }
void fw_app_show(fw_app *p0) {  }
int fw_app_pump(fw_app *p0, int timeout_ms) { return 0; }
void fw_app_destroy(fw_app *p0) {  }
float fw_dpi_scale(fw_app *p0) { return 1.0f; }
void fw_set_title(fw_app *p0, const char *title) {  }
void fw_set_menu_check(fw_app *p0, int id, int checked) {  }
void fw_set_menu_enabled(fw_app *p0, int id, int enabled) {  }
void fw_set_status(fw_app *p0, const char *left, const char *middle, const char *right) {  }
void fw_set_tab(fw_app *p0, int index) {  }
void fw_ribbon_begin(fw_app *p0) {  }
void fw_ribbon_group(fw_app *p0, const char *title) {  }
void fw_ribbon_button(fw_app *p0, const char *title, const char *help, int large, int active, int enabled, const char *variants) {  }
void fw_ribbon_end(fw_app *p0) {  }
void fw_tree_begin(fw_app *p0) {  }
void fw_tree_node(fw_app *p0, int depth, const char *title, const char *tooltip, int state, int selected, const char *menu) {  }
void fw_tree_end(fw_app *p0) {  }
void fw_panel_begin(fw_app *p0, const char *title, const char *subtitle, const char *message, int has_ok, int has_cancel) {  }
void fw_panel_section(fw_app *p0, const char *title, int toggle) {  }
void fw_panel_field(fw_app *p0, const char *label, const char *unit, const char *value) {  }
void fw_panel_check(fw_app *p0, const char *label, int value) {  }
void fw_panel_choice(fw_app *p0, const char *label, const char *options, int selected) {  }
void fw_panel_list(fw_app *p0, const char *items, const char *placeholder, int active) {  }
void fw_panel_note(fw_app *p0, const char *text, int warning) {  }
void fw_panel_value(fw_app *p0, const char *label, const char *value) {  }
void fw_panel_buttons(fw_app *p0, const char *titles) {  }
void fw_panel_rows(fw_app *p0, const char *texts, const char *details, const char *problems, int deletable) {  }
void fw_panel_end(fw_app *p0) {  }
void fw_panel_set_text(fw_app *p0, int control, const char *value) {  }
void fw_panel_set_check(fw_app *p0, int control, int value) {  }
void fw_panel_set_choice(fw_app *p0, int control, int index) {  }
void fw_edit_show(fw_app *p0, int x, int y, const char *label, const char *value) {  }
void fw_edit_hide(fw_app *p0) {  }
int fw_confirm(fw_app *p0, const char *title, const char *message, const char *yes, const char *no) { return 0; }
char * fw_save_dialog(fw_app *p0, const char *suggested_name) { return NULL; }
char * fw_open_dialog(fw_app *p0) { return NULL; }
void fw_message(fw_app *p0, const char *title, const char *message, int error) {  }
void fw_free(void *ptr) { free(ptr); }
void fw_view_invalidate(fw_app *p0) {  }
void fw_view_size(fw_app *p0, int *width, int *height) { if (width) *width = 800; if (height) *height = 600; }
void fw_view_focus(fw_app *p0) {  }
fw_buffer * fw_buffer_create(fw_app *p0, const void *bytes, int length) { return NULL; }
void fw_buffer_release(fw_buffer *p0) {  }
int fw_frame_begin(fw_app *p0, const float top[4], const float bottom[4]) { return 0; }
void fw_draw(fw_app *p0, int pipeline, int depth, fw_buffer *p3, int vertex_count, const float *uniforms) {  }
void fw_text(fw_app *p0, const char *text, float x, float y, float size, uint32_t rgba, int align, int boxed) {  }
void fw_line2d(fw_app *p0, float x0, float y0, float x1, float y1, float width, uint32_t rgba) {  }
void fw_frame_end(fw_app *p0) {  }
int fw_pick_begin(fw_app *p0) { return 0; }
int fw_pick_end(fw_app *p0, int x0, int y0, int w, int h, uint32_t *objects, uint32_t *elements) { return 0; }
