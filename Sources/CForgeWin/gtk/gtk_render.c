// OpenGL 3.3 viewport renderer of the Linux shell: executes the draw plan of
// ForgeRender.ViewportPlan with GLSL equivalents of the Metal and HLSL pipelines, GPU picking
// into two R32UI targets, and a Cairo / Pango layer for labels. It lives in a GtkGLArea.
//
// Clip space: the plan's projection is Metal / Direct3D style (z in [0, w]); the vertex
// shaders map it to OpenGL's [-w, w]. Colours are written as sRGB, like the Metal and D3D
// sRGB targets.

#include "gtk_internal.h"

#include <epoxy/gl.h>
#include <pango/pangocairo.h>
#include <stdlib.h>
#include <string.h>

struct fw_buffer {
    void *bytes;       // kept until uploaded (the GL context may not exist yet)
    int length;
    GLuint vbo;
    fw_app *app;
};

typedef enum { OP_TEXT, OP_LINE } OverlayKind;

typedef struct {
    OverlayKind kind;
    char *text;
    float x, y, x1, y1, size, width;
    uint32_t rgba;
    int align, boxed;
} OverlayOp;

struct fw_renderer {
    int ready;
    GLuint vao, emptyVAO;
    GLuint shaded, lines, preview, pick, pickLines, gradient, overlay;
    GLuint overlayTex, overlayVBO;
    GLuint pickFBO, pickObj, pickEl, pickDepth;
    int pickW, pickH;
    GLint frameFBO;
    int inFrame;
    GArray *ops;       // OverlayOp
};

static const char *kCommon =
    "#version 330 core\n"
    "uniform mat4 viewProj;\n"
    "uniform vec4 color;\n"
    "uniform vec4 highlight;\n"
    "uniform vec4 lightDir;\n"
    "uniform vec4 viewDir;\n"
    "uniform uvec4 ids;\n"
    "vec3 toSRGB(vec3 c) { c = clamp(c, 0.0, 1.0); return mix(c * 12.92, 1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, step(0.0031308, c)); }\n"
    "vec4 glClip(vec4 p) { p.z = 2.0 * p.z - p.w; return p; }\n";

static const char *kTriVS =
    "layout(location = 0) in vec3 position;\n"
    "layout(location = 1) in vec3 normal;\n"
    "layout(location = 2) in uint element;\n"
    "layout(location = 3) in uint highlighted;\n"
    "out vec3 vNormal;\n"
    "flat out uint vElement;\n"
    "flat out uint vHighlighted;\n"
    "void main() {\n"
    "  gl_Position = glClip(viewProj * vec4(position, 1.0));\n"
    "  vNormal = normal; vElement = element; vHighlighted = highlighted;\n"
    "}\n";

static const char *kLineVS =
    "layout(location = 0) in vec3 position;\n"
    "layout(location = 2) in uint element;\n"
    "layout(location = 3) in uint highlighted;\n"
    "layout(location = 4) in vec3 lineColor;\n"
    "out vec3 vColor;\n"
    "flat out uint vElement;\n"
    "flat out uint vHighlighted;\n"
    "void main() {\n"
    "  vec4 p = viewProj * vec4(position, 1.0);\n"
    "  p.z -= 0.0015 * p.w;  // edges on top of their faces\n"
    "  gl_Position = glClip(p);\n"
    "  vColor = lineColor; vElement = element; vHighlighted = highlighted;\n"
    "}\n";

static const char *kShadedFS =
    "in vec3 vNormal;\n"
    "flat in uint vElement;\n"
    "flat in uint vHighlighted;\n"
    "out vec4 outColor;\n"
    "void main() {\n"
    "  if (ids.y != 0u) { outColor = vec4(1.0); return; }\n"
    "  vec3 base = vHighlighted != 0u ? highlight.rgb : color.rgb;\n"
    "  vec3 n = normalize(vNormal);\n"
    "  if (dot(n, viewDir.xyz) < 0.0) n = -n;\n"
    "  float diffuse = max(0.0, dot(n, lightDir.xyz));\n"
    "  vec3 h = normalize(lightDir.xyz + viewDir.xyz);\n"
    "  float spec = pow(max(0.0, dot(n, h)), 40.0) * 0.25;\n"
    "  outColor = vec4(toSRGB(min(vec3(1.0), base * (0.3 + 0.7 * diffuse) + spec)), 1.0);\n"
    "}\n";

static const char *kPreviewFS =
    "in vec3 vNormal;\n"
    "flat in uint vElement;\n"
    "flat in uint vHighlighted;\n"
    "out vec4 outColor;\n"
    "void main() {\n"
    "  vec3 n = normalize(vNormal);\n"
    "  if (dot(n, viewDir.xyz) < 0.0) n = -n;\n"
    "  float diffuse = max(0.0, dot(n, lightDir.xyz));\n"
    "  outColor = vec4(toSRGB(color.rgb * (0.55 + 0.45 * diffuse)), color.a);\n"
    "}\n";

static const char *kLineFS =
    "in vec3 vColor;\n"
    "flat in uint vElement;\n"
    "flat in uint vHighlighted;\n"
    "out vec4 outColor;\n"
    "void main() { outColor = vec4(toSRGB(vHighlighted != 0u ? highlight.rgb : vColor), 1.0); }\n";

static const char *kPickTriFS =
    "in vec3 vNormal;\n"
    "flat in uint vElement;\n"
    "flat in uint vHighlighted;\n"
    "layout(location = 0) out uint outObject;\n"
    "layout(location = 1) out uint outElement;\n"
    "void main() { outObject = ids.x; outElement = vElement; }\n";

static const char *kPickLineFS =
    "in vec3 vColor;\n"
    "flat in uint vElement;\n"
    "flat in uint vHighlighted;\n"
    "layout(location = 0) out uint outObject;\n"
    "layout(location = 1) out uint outElement;\n"
    "void main() { outObject = ids.x; outElement = vElement; }\n";

// Background: a full-screen triangle with a vertical gradient (colour = top, highlight = bottom).
static const char *kGradientVS =
    "out float t;\n"
    "void main() {\n"
    "  vec2 p = vec2(float((gl_VertexID << 1) & 2), float(gl_VertexID & 2));\n"
    "  gl_Position = vec4(p * vec2(2.0, -2.0) + vec2(-1.0, 1.0), 1.0, 1.0);\n"
    "  t = p.y;\n"
    "}\n";

static const char *kGradientFS =
    "in float t;\n"
    "out vec4 outColor;\n"
    "void main() { vec4 c = mix(color, highlight, clamp(t, 0.0, 1.0)); outColor = vec4(toSRGB(c.rgb), c.a); }\n";

// 2D overlay: a premultiplied texture over the viewport.
static const char *kOverlayVS =
    "#version 330 core\n"
    "layout(location = 0) in vec2 p;\n"
    "out vec2 uv;\n"
    "void main() { uv = vec2(p.x, 1.0 - p.y); gl_Position = vec4(p * 2.0 - 1.0, 0.0, 1.0); }\n";

static const char *kOverlayFS =
    "#version 330 core\n"
    "in vec2 uv;\n"
    "uniform sampler2D tex;\n"
    "out vec4 outColor;\n"
    "void main() { vec4 c = texture(tex, uv); outColor = vec4(c.b, c.g, c.r, c.a); }\n";

static GLuint compile(GLenum type, const char *common, const char *body) {
    GLuint s = glCreateShader(type);
    const char *src[2] = {common ? common : "", body};
    glShaderSource(s, 2, src, NULL);
    glCompileShader(s);
    GLint ok = 0;
    glGetShaderiv(s, GL_COMPILE_STATUS, &ok);
    if (!ok) {
        char log[2048];
        glGetShaderInfoLog(s, sizeof log, NULL, log);
        g_warning("Forge viewport: shader compile failed: %s", log);
        glDeleteShader(s);
        return 0;
    }
    return s;
}

static GLuint program(const char *vs, const char *fs, int common) {
    GLuint v = compile(GL_VERTEX_SHADER, common ? kCommon : NULL, vs), f = compile(GL_FRAGMENT_SHADER, common ? kCommon : NULL, fs);
    if (!v || !f) return 0;
    GLuint p = glCreateProgram();
    glAttachShader(p, v);
    glAttachShader(p, f);
    glLinkProgram(p);
    glDeleteShader(v);
    glDeleteShader(f);
    GLint ok = 0;
    glGetProgramiv(p, GL_LINK_STATUS, &ok);
    if (!ok) {
        char log[2048];
        glGetProgramInfoLog(p, sizeof log, NULL, log);
        g_warning("Forge viewport: program link failed: %s", log);
        glDeleteProgram(p);
        return 0;
    }
    return p;
}

fw_renderer *fw_renderer_create(void) {
    fw_renderer *r = g_new0(fw_renderer, 1);
    r->ops = g_array_new(FALSE, TRUE, sizeof(OverlayOp));
    return r;
}

static void clearOps(fw_renderer *r) {
    for (guint i = 0; i < r->ops->len; ++i) g_free(g_array_index(r->ops, OverlayOp, i).text);
    g_array_set_size(r->ops, 0);
}

void fw_renderer_destroy(fw_renderer *r) {
    if (!r) return;
    clearOps(r);
    g_array_unref(r->ops);
    g_free(r);
}

static void releasePick(fw_renderer *r) {
    if (r->pickFBO) glDeleteFramebuffers(1, &r->pickFBO);
    if (r->pickObj) glDeleteTextures(1, &r->pickObj);
    if (r->pickEl) glDeleteTextures(1, &r->pickEl);
    if (r->pickDepth) glDeleteRenderbuffers(1, &r->pickDepth);
    r->pickFBO = r->pickObj = r->pickEl = r->pickDepth = 0;
    r->pickW = r->pickH = 0;
}

void fw_render_realize(fw_app *a) {
    fw_renderer *r = a->renderer;
    gtk_gl_area_make_current(GTK_GL_AREA(a->view));
    if (gtk_gl_area_get_error(GTK_GL_AREA(a->view))) return;
    r->shaded = program(kTriVS, kShadedFS, 1);
    r->preview = program(kTriVS, kPreviewFS, 1);
    r->pick = program(kTriVS, kPickTriFS, 1);
    r->lines = program(kLineVS, kLineFS, 1);
    r->pickLines = program(kLineVS, kPickLineFS, 1);
    r->gradient = program(kGradientVS, kGradientFS, 1);
    r->overlay = program(kOverlayVS, kOverlayFS, 0);
    glGenVertexArrays(1, &r->vao);
    glGenVertexArrays(1, &r->emptyVAO);
    glGenTextures(1, &r->overlayTex);
    glGenBuffers(1, &r->overlayVBO);
    static const float quad[] = {0, 0, 1, 0, 0, 1, 1, 1};
    glBindBuffer(GL_ARRAY_BUFFER, r->overlayVBO);
    glBufferData(GL_ARRAY_BUFFER, sizeof quad, quad, GL_STATIC_DRAW);
    r->ready = r->shaded && r->preview && r->pick && r->lines && r->pickLines && r->gradient && r->overlay;
}

void fw_render_unrealize(fw_app *a) {
    fw_renderer *r = a->renderer;
    gtk_gl_area_make_current(GTK_GL_AREA(a->view));
    if (gtk_gl_area_get_error(GTK_GL_AREA(a->view))) return;
    releasePick(r);
    GLuint progs[] = {r->shaded, r->preview, r->pick, r->lines, r->pickLines, r->gradient, r->overlay};
    for (size_t i = 0; i < sizeof progs / sizeof progs[0]; ++i)
        if (progs[i]) glDeleteProgram(progs[i]);
    glDeleteVertexArrays(1, &r->vao);
    glDeleteVertexArrays(1, &r->emptyVAO);
    glDeleteTextures(1, &r->overlayTex);
    glDeleteBuffers(1, &r->overlayVBO);
    r->ready = 0;
}

// MARK: the GtkGLArea and its input

static gboolean onRender(GtkGLArea *area, GdkGLContext *ctx, gpointer data) {
    (void)area;
    (void)ctx;
    fw_app *a = data;
    fw_emit(a, fw_event_make(FW_EV_PAINT, 0, 0));
    return TRUE;
}

static void onResize(GtkGLArea *area, int width, int height, gpointer data) {
    fw_app *a = data;
    a->viewWidth = width;
    a->viewHeight = height;
    int lw = gtk_widget_get_width(GTK_WIDGET(area));
    a->scale = lw > 0 ? (float)width / (float)lw : 1.0f;
    fw_event e = fw_event_make(FW_EV_RESIZE, 0, 0);
    e.x = width;
    e.y = height;
    fw_emit(a, e);
}

static void onRealize(GtkWidget *w, gpointer data) {
    (void)w;
    fw_render_realize((fw_app *)data);
}

static void onUnrealize(GtkWidget *w, gpointer data) {
    fw_app *a = data;
    if (a->view == w) fw_render_unrealize(a);
}

static int buttonOf(guint b) { return b == GDK_BUTTON_PRIMARY ? 0 : b == GDK_BUTTON_SECONDARY ? 1 : b == GDK_BUTTON_MIDDLE ? 2 : -1; }

static int heldButton(GdkModifierType m) {
    return (m & GDK_BUTTON1_MASK) ? 0 : (m & GDK_BUTTON3_MASK) ? 1 : (m & GDK_BUTTON2_MASK) ? 2 : -1;
}

static fw_event mouse(fw_app *a, GtkEventController *c, int kind, double x, double y) {
    fw_event e = fw_event_make(kind, 0, 0);
    e.x = (int)(x * a->scale);
    e.y = (int)(y * a->scale);
    GdkModifierType m = gtk_event_controller_get_current_event_state(c);
    e.mods = ((m & GDK_SHIFT_MASK) ? FW_MOD_SHIFT : 0) | ((m & GDK_CONTROL_MASK) ? FW_MOD_CTRL : 0) | ((m & GDK_ALT_MASK) ? FW_MOD_ALT : 0);
    e.clicks = 1;
    return e;
}

static void onPress(GtkGestureClick *g, int n, double x, double y, gpointer data) {
    fw_app *a = data;
    gtk_widget_grab_focus(a->view);
    fw_event e = mouse(a, GTK_EVENT_CONTROLLER(g), FW_EV_MOUSE_DOWN, x, y);
    e.button = buttonOf(gtk_gesture_single_get_current_button(GTK_GESTURE_SINGLE(g)));
    e.clicks = n >= 2 ? 2 : 1;
    if (e.button >= 0) fw_emit(a, e);
}

static void onRelease(GtkGestureClick *g, int n, double x, double y, gpointer data) {
    (void)n;
    fw_app *a = data;
    fw_event e = mouse(a, GTK_EVENT_CONTROLLER(g), FW_EV_MOUSE_UP, x, y);
    e.button = buttonOf(gtk_gesture_single_get_current_button(GTK_GESTURE_SINGLE(g)));
    if (e.button >= 0) fw_emit(a, e);
}

static void onMotion(GtkEventControllerMotion *m, double x, double y, gpointer data) {
    fw_app *a = data;
    fw_event e = mouse(a, GTK_EVENT_CONTROLLER(m), FW_EV_MOUSE_MOVE, x, y);
    e.button = heldButton(gtk_event_controller_get_current_event_state(GTK_EVENT_CONTROLLER(m)));
    fw_emit(a, e);
}

static void onLeave(GtkEventControllerMotion *m, gpointer data) {
    (void)m;
    fw_emit((fw_app *)data, fw_event_make(FW_EV_MOUSE_LEAVE, 0, 0));
}

static double lastX, lastY;

static void onPointer(GtkEventControllerMotion *m, double x, double y, gpointer data) {
    (void)m;
    (void)data;
    lastX = x;
    lastY = y;
}

static gboolean onScroll(GtkEventControllerScroll *s, double dx, double dy, gpointer data) {
    (void)dx;
    fw_app *a = data;
    fw_event e = mouse(a, GTK_EVENT_CONTROLLER(s), FW_EV_MOUSE_WHEEL, lastX, lastY);
    e.wheel = (float)-dy;  // GTK: positive = toward the user; the API: positive = away
    fw_emit(a, e);
    return TRUE;
}

static gboolean onKey(GtkEventControllerKey *k, guint keyval, guint code, GdkModifierType state, gpointer data) {
    (void)code;
    fw_app *a = data;
    if (state & (GDK_CONTROL_MASK | GDK_ALT_MASK)) return FALSE;  // menu shortcuts
    const char *name = NULL;
    char text[8] = {0};
    switch (keyval) {
    case GDK_KEY_Return:
    case GDK_KEY_KP_Enter: name = "return"; break;
    case GDK_KEY_Escape: name = "escape"; break;
    case GDK_KEY_Delete:
    case GDK_KEY_BackSpace: name = "delete"; break;
    case GDK_KEY_space: name = "space"; break;
    case GDK_KEY_Tab: name = "tab"; break;
    default: {
        gunichar c = gdk_keyval_to_unicode(keyval);
        if (c < 32 || c == 127) return FALSE;
        g_unichar_to_utf8(c, text);
        name = text;
    }
    }
    fw_event e = fw_event_make(FW_EV_KEY, 0, 0);
    e.text = name;
    e.mods = ((state & GDK_SHIFT_MASK) ? FW_MOD_SHIFT : 0);
    (void)k;
    fw_emit(a, e);
    return TRUE;
}

GtkWidget *fw_render_create_view(fw_app *a) {
    GtkWidget *area = gtk_gl_area_new();
    a->view = area;
    gtk_gl_area_set_required_version(GTK_GL_AREA(area), 3, 3);
#if GTK_CHECK_VERSION(4, 12, 0)
    gtk_gl_area_set_allowed_apis(GTK_GL_AREA(area), GDK_GL_API_GL);
#endif
    gtk_gl_area_set_has_depth_buffer(GTK_GL_AREA(area), TRUE);
    gtk_gl_area_set_auto_render(GTK_GL_AREA(area), FALSE);
    gtk_widget_set_hexpand(area, TRUE);
    gtk_widget_set_vexpand(area, TRUE);
    gtk_widget_set_focusable(area, TRUE);
    g_signal_connect(area, "realize", G_CALLBACK(onRealize), a);
    g_signal_connect(area, "unrealize", G_CALLBACK(onUnrealize), a);
    g_signal_connect(area, "render", G_CALLBACK(onRender), a);
    g_signal_connect(area, "resize", G_CALLBACK(onResize), a);

    GtkGesture *click = gtk_gesture_click_new();
    gtk_gesture_single_set_button(GTK_GESTURE_SINGLE(click), 0);
    g_signal_connect(click, "pressed", G_CALLBACK(onPress), a);
    g_signal_connect(click, "released", G_CALLBACK(onRelease), a);
    gtk_widget_add_controller(area, GTK_EVENT_CONTROLLER(click));
    GtkEventController *motion = gtk_event_controller_motion_new();
    g_signal_connect(motion, "motion", G_CALLBACK(onMotion), a);
    g_signal_connect(motion, "motion", G_CALLBACK(onPointer), a);
    g_signal_connect(motion, "leave", G_CALLBACK(onLeave), a);
    gtk_widget_add_controller(area, motion);
    GtkEventController *scroll = gtk_event_controller_scroll_new(GTK_EVENT_CONTROLLER_SCROLL_VERTICAL);
    g_signal_connect(scroll, "scroll", G_CALLBACK(onScroll), a);
    gtk_widget_add_controller(area, scroll);
    GtkEventController *keys = gtk_event_controller_key_new();
    g_signal_connect(keys, "key-pressed", G_CALLBACK(onKey), a);
    gtk_widget_add_controller(area, keys);
    return area;
}

// MARK: C API

void fw_view_invalidate(fw_app *a) {
    if (a->view) gtk_gl_area_queue_render(GTK_GL_AREA(a->view));
}

void fw_view_size(fw_app *a, int *width, int *height) {
    *width = a->viewWidth;
    *height = a->viewHeight;
}

void fw_view_focus(fw_app *a) {
    if (a->view) gtk_widget_grab_focus(a->view);
}

/// Make the viewport's GL context current (for work outside its render signal).
static int current(fw_app *a) {
    if (!a->view || !gtk_widget_get_realized(a->view) || !a->renderer->ready) return 0;
    gtk_gl_area_make_current(GTK_GL_AREA(a->view));
    return gtk_gl_area_get_error(GTK_GL_AREA(a->view)) == NULL;
}

fw_buffer *fw_buffer_create(fw_app *a, const void *bytes, int length) {
    if (!bytes || length <= 0) return NULL;
    fw_buffer *b = g_new0(fw_buffer, 1);
    b->bytes = g_memdup2(bytes, (gsize)length);
    b->length = length;
    b->app = a;
    return b;
}

void fw_buffer_release(fw_buffer *b) {
    if (!b) return;
    if (b->vbo && current(b->app)) glDeleteBuffers(1, &b->vbo);
    g_free(b->bytes);
    g_free(b);
}

static void setUniforms(GLuint prog, const float *u) {
    glUniformMatrix4fv(glGetUniformLocation(prog, "viewProj"), 1, GL_FALSE, u);
    glUniform4fv(glGetUniformLocation(prog, "color"), 1, u + 16);
    glUniform4fv(glGetUniformLocation(prog, "highlight"), 1, u + 20);
    glUniform4fv(glGetUniformLocation(prog, "lightDir"), 1, u + 24);
    glUniform4fv(glGetUniformLocation(prog, "viewDir"), 1, u + 28);
    uint32_t ids[4];
    memcpy(ids, u + 32, sizeof ids);  // bit patterns, see ViewportPlan.uniforms
    glUniform4ui(glGetUniformLocation(prog, "ids"), ids[0], ids[1], ids[2], ids[3]);
}

int fw_frame_begin(fw_app *a, const float top[4], const float bottom[4]) {
    fw_renderer *r = a->renderer;
    if (!r->ready || a->viewWidth <= 0) return 0;
    glGetIntegerv(GL_FRAMEBUFFER_BINDING, &r->frameFBO);
    r->inFrame = 1;
    clearOps(r);
    glViewport(0, 0, a->viewWidth, a->viewHeight);
    glClearDepth(1.0);
    glClear(GL_DEPTH_BUFFER_BIT);
    glDisable(GL_DEPTH_TEST);
    glDisable(GL_BLEND);
    glDisable(GL_CULL_FACE);
    float u[36] = {0};
    memcpy(u + 16, top, 16);
    memcpy(u + 20, bottom, 16);
    glUseProgram(r->gradient);
    setUniforms(r->gradient, u);
    glBindVertexArray(r->emptyVAO);
    glDrawArrays(GL_TRIANGLES, 0, 3);
    return 1;
}

void fw_draw(fw_app *a, int pipeline, int depth, fw_buffer *b, int vertex_count, const float *u) {
    fw_renderer *r = a->renderer;
    if (!r->ready || !b || vertex_count <= 0) return;
    int lines = pipeline == 1 || pipeline == 4;
    GLuint prog = pipeline == 0 ? r->shaded : pipeline == 1 ? r->lines : pipeline == 2 ? r->preview : pipeline == 3 ? r->pick : r->pickLines;
    glUseProgram(prog);
    setUniforms(prog, u);
    glBindVertexArray(r->vao);
    if (!b->vbo) {
        glGenBuffers(1, &b->vbo);
        glBindBuffer(GL_ARRAY_BUFFER, b->vbo);
        glBufferData(GL_ARRAY_BUFFER, b->length, b->bytes, GL_STATIC_DRAW);
    }
    glBindBuffer(GL_ARRAY_BUFFER, b->vbo);
    // Must match ForgeRender.ViewportVertices (32-byte vertices).
    for (GLuint i = 0; i < 5; ++i) glDisableVertexAttribArray(i);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 32, (void *)0);
    glEnableVertexAttribArray(2);
    glEnableVertexAttribArray(3);
    if (lines) {
        glVertexAttribIPointer(2, 1, GL_UNSIGNED_INT, 32, (void *)12);
        glVertexAttribIPointer(3, 1, GL_UNSIGNED_INT, 32, (void *)16);
        glEnableVertexAttribArray(4);
        glVertexAttribPointer(4, 3, GL_FLOAT, GL_FALSE, 32, (void *)20);
    } else {
        glEnableVertexAttribArray(1);
        glVertexAttribPointer(1, 3, GL_FLOAT, GL_FALSE, 32, (void *)12);
        glVertexAttribIPointer(2, 1, GL_UNSIGNED_INT, 32, (void *)24);
        glVertexAttribIPointer(3, 1, GL_UNSIGNED_INT, 32, (void *)28);
    }
    if (pipeline == 2) {
        glEnable(GL_BLEND);
        glBlendFuncSeparate(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA, GL_ONE, GL_ONE_MINUS_SRC_ALPHA);
    } else {
        glDisable(GL_BLEND);
    }
    if (depth == 2) {
        glDisable(GL_DEPTH_TEST);
    } else {
        glEnable(GL_DEPTH_TEST);
        glDepthFunc(GL_LEQUAL);
        glDepthMask(depth == 0 ? GL_TRUE : GL_FALSE);
    }
    glDrawArrays(lines ? GL_LINES : GL_TRIANGLES, 0, vertex_count);
    glDepthMask(GL_TRUE);
}

void fw_text(fw_app *a, const char *text, float x, float y, float size, uint32_t rgba, int align, int boxed) {
    fw_renderer *r = a->renderer;
    if (!r->inFrame || !text || !*text) return;
    OverlayOp op = {OP_TEXT, g_strdup(text), x, y, 0, 0, size, 0, rgba, align, boxed};
    g_array_append_val(r->ops, op);
}

void fw_line2d(fw_app *a, float x0, float y0, float x1, float y1, float width, uint32_t rgba) {
    fw_renderer *r = a->renderer;
    if (!r->inFrame) return;
    OverlayOp op = {OP_LINE, NULL, x0, y0, x1, y1, 0, width, rgba, 0, 0};
    g_array_append_val(r->ops, op);
}

static void setColor(cairo_t *cr, uint32_t rgba) {
    cairo_set_source_rgba(cr, ((rgba >> 24) & 255) / 255.0, ((rgba >> 16) & 255) / 255.0, ((rgba >> 8) & 255) / 255.0, (rgba & 255) / 255.0);
}

static void roundedRect(cairo_t *cr, double x, double y, double w, double h, double r) {
    cairo_new_sub_path(cr);
    cairo_arc(cr, x + w - r, y + r, r, -G_PI / 2, 0);
    cairo_arc(cr, x + w - r, y + h - r, r, 0, G_PI / 2);
    cairo_arc(cr, x + r, y + h - r, r, G_PI / 2, G_PI);
    cairo_arc(cr, x + r, y + r, r, G_PI, 3 * G_PI / 2);
    cairo_close_path(cr);
}

/// The labels and 2D lines of the frame, drawn with Cairo and composited over the 3D view.
static void drawOverlay(fw_app *a) {
    fw_renderer *r = a->renderer;
    if (r->ops->len == 0) return;
    int W = a->viewWidth, H = a->viewHeight;
    cairo_surface_t *s = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, W, H);
    cairo_t *cr = cairo_create(s);
    PangoLayout *layout = pango_cairo_create_layout(cr);
    PangoFontDescription *font = pango_font_description_from_string("Sans Semi-Bold");
    for (guint i = 0; i < r->ops->len; ++i) {
        OverlayOp *op = &g_array_index(r->ops, OverlayOp, i);
        if (op->kind == OP_LINE) {
            setColor(cr, op->rgba);
            cairo_set_line_width(cr, op->width);
            cairo_move_to(cr, op->x, op->y);
            cairo_line_to(cr, op->x1, op->y1);
            cairo_stroke(cr);
            continue;
        }
        pango_font_description_set_absolute_size(font, op->size * PANGO_SCALE);
        pango_layout_set_font_description(layout, font);
        pango_layout_set_text(layout, op->text, -1);
        int tw, th;
        pango_layout_get_pixel_size(layout, &tw, &th);
        double left = op->align == 1 ? op->x - tw / 2.0 : op->x, top = op->y - th / 2.0;
        if (op->boxed) {
            double pad = op->size * 0.45, bh = op->size * 1.4;
            roundedRect(cr, left - pad, op->y - bh / 2, tw + 2 * pad, bh, op->size * 0.35);
            cairo_set_source_rgba(cr, 1, 1, 1, 0.92);
            cairo_fill_preserve(cr);
            cairo_set_source_rgba(cr, 0.78, 0.80, 0.84, 1);
            cairo_set_line_width(cr, 1);
            cairo_stroke(cr);
        }
        setColor(cr, op->rgba);
        cairo_move_to(cr, left, top);
        pango_cairo_show_layout(cr, layout);
    }
    pango_font_description_free(font);
    g_object_unref(layout);
    cairo_destroy(cr);
    cairo_surface_flush(s);

    glBindTexture(GL_TEXTURE_2D, r->overlayTex);
    glPixelStorei(GL_UNPACK_ROW_LENGTH, cairo_image_surface_get_stride(s) / 4);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA8, W, H, 0, GL_RGBA, GL_UNSIGNED_BYTE, cairo_image_surface_get_data(s));
    glPixelStorei(GL_UNPACK_ROW_LENGTH, 0);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    cairo_surface_destroy(s);
    glDisable(GL_DEPTH_TEST);
    glEnable(GL_BLEND);
    glBlendFunc(GL_ONE, GL_ONE_MINUS_SRC_ALPHA);  // Cairo is premultiplied
    glUseProgram(r->overlay);
    glUniform1i(glGetUniformLocation(r->overlay, "tex"), 0);
    glActiveTexture(GL_TEXTURE0);
    glBindVertexArray(r->vao);
    for (GLuint i = 0; i < 5; ++i) glDisableVertexAttribArray(i);
    glBindBuffer(GL_ARRAY_BUFFER, r->overlayVBO);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 8, (void *)0);
    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    glDisable(GL_BLEND);
}

void fw_frame_end(fw_app *a) {
    fw_renderer *r = a->renderer;
    if (!r->inFrame) return;
    drawOverlay(a);
    clearOps(r);
    r->inFrame = 0;
}

// MARK: picking

int fw_pick_begin(fw_app *a) {
    fw_renderer *r = a->renderer;
    int inFrame = r->inFrame;
    if (!inFrame && !current(a)) return 0;
    if (!r->ready || a->viewWidth <= 0) return 0;
    if (!inFrame) glGetIntegerv(GL_FRAMEBUFFER_BINDING, &r->frameFBO);
    if (r->pickW != a->viewWidth || r->pickH != a->viewHeight || !r->pickFBO) {
        releasePick(r);
        int W = a->viewWidth, H = a->viewHeight;
        glGenFramebuffers(1, &r->pickFBO);
        glBindFramebuffer(GL_FRAMEBUFFER, r->pickFBO);
        GLuint *targets[2] = {&r->pickObj, &r->pickEl};
        for (int t = 0; t < 2; ++t) {
            glGenTextures(1, targets[t]);
            glBindTexture(GL_TEXTURE_2D, *targets[t]);
            glTexImage2D(GL_TEXTURE_2D, 0, GL_R32UI, W, H, 0, GL_RED_INTEGER, GL_UNSIGNED_INT, NULL);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
            glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
            glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0 + t, GL_TEXTURE_2D, *targets[t], 0);
        }
        glGenRenderbuffers(1, &r->pickDepth);
        glBindRenderbuffer(GL_RENDERBUFFER, r->pickDepth);
        glRenderbufferStorage(GL_RENDERBUFFER, GL_DEPTH_COMPONENT24, W, H);
        glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_DEPTH_ATTACHMENT, GL_RENDERBUFFER, r->pickDepth);
        if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) {
            glBindFramebuffer(GL_FRAMEBUFFER, (GLuint)r->frameFBO);
            releasePick(r);
            return 0;
        }
        r->pickW = W;
        r->pickH = H;
    }
    glBindFramebuffer(GL_FRAMEBUFFER, r->pickFBO);
    GLenum bufs[2] = {GL_COLOR_ATTACHMENT0, GL_COLOR_ATTACHMENT1};
    glDrawBuffers(2, bufs);
    glViewport(0, 0, r->pickW, r->pickH);
    GLuint zero[4] = {0, 0, 0, 0};
    glClearBufferuiv(GL_COLOR, 0, zero);
    glClearBufferuiv(GL_COLOR, 1, zero);
    glClearDepth(1.0);
    glClear(GL_DEPTH_BUFFER_BIT);
    glDisable(GL_BLEND);
    return 1;
}

int fw_pick_end(fw_app *a, int x0, int y0, int w, int h, uint32_t *objects, uint32_t *elements) {
    fw_renderer *r = a->renderer;
    if (!r->pickFBO || w <= 0 || h <= 0) return 0;
    // The API's origin is the top-left pixel; OpenGL's is the bottom-left.
    int gy = r->pickH - (y0 + h);
    uint32_t *tmp = g_new(uint32_t, (size_t)w * h);
    for (int t = 0; t < 2; ++t) {
        glReadBuffer(GL_COLOR_ATTACHMENT0 + t);
        glPixelStorei(GL_PACK_ALIGNMENT, 4);
        glReadPixels(x0, gy, w, h, GL_RED_INTEGER, GL_UNSIGNED_INT, tmp);
        uint32_t *out = t == 0 ? objects : elements;
        for (int row = 0; row < h; ++row) memcpy(out + (size_t)row * w, tmp + (size_t)(h - 1 - row) * w, (size_t)w * 4);
    }
    g_free(tmp);
    glBindFramebuffer(GL_FRAMEBUFFER, (GLuint)r->frameFBO);
    glViewport(0, 0, a->viewWidth, a->viewHeight);
    return glGetError() == GL_NO_ERROR;
}
