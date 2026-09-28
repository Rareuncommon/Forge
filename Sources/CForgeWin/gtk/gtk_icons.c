// Forge's icon set in the Linux shell: the geometry the front end defines (fw_icon_define,
// from ForgeUI's IconGeometry — the same drawings as the macOS app) drawn with Cairo in a
// GtkDrawingArea, in the widget's CSS colour (so hover, active and disabled states follow)
// with accent layers in the theme's accent.

#include "gtk_internal.h"

#include <stdlib.h>
#include <string.h>

enum { PAINT_STROKE, PAINT_ACCENT, PAINT_DASHED, PAINT_ACCENT_DASHED, PAINT_FILL, PAINT_ACCENT_FILL };
enum { OP_MOVE, OP_LINE, OP_CUBIC, OP_CLOSE };

typedef struct {
    int paint;
    GArray *ops;  // double: opcode, then its coordinates
} Layer;

static GHashTable *icons;  // name → GPtrArray of Layer *
static GdkRGBA accent = {0.122, 0.373, 0.839, 1};

void fw_icons_set_accent(GdkRGBA c) { accent = c; }

static void freeLayers(gpointer p) {
    GPtrArray *layers = p;
    for (guint i = 0; i < layers->len; ++i) {
        Layer *l = g_ptr_array_index(layers, i);
        g_array_unref(l->ops);
        g_free(l);
    }
    g_ptr_array_unref(layers);
}

void fw_icon_define(fw_app *a, const char *name, const char *geometry) {
    (void)a;
    if (!name || !geometry) return;
    if (!icons) icons = g_hash_table_new_full(g_str_hash, g_str_equal, g_free, freeLayers);
    GPtrArray *layers = g_ptr_array_new();
    char **parts = g_strsplit(geometry, "|", -1);
    for (int p = 0; parts[p]; ++p) {
        char **tok = g_strsplit_set(g_strstrip(parts[p]), " ", -1);
        Layer *l = g_new0(Layer, 1);
        l->ops = g_array_new(FALSE, FALSE, sizeof(double));
        const char *paint = tok[0] ? tok[0] : "s";
        l->paint = !strcmp(paint, "a") ? PAINT_ACCENT : !strcmp(paint, "d") ? PAINT_DASHED : !strcmp(paint, "ad") ? PAINT_ACCENT_DASHED
                 : !strcmp(paint, "f") ? PAINT_FILL : !strcmp(paint, "af") ? PAINT_ACCENT_FILL : PAINT_STROKE;
        for (int i = 1; tok[i]; ++i) {
            if (!*tok[i]) continue;
            int n = -1;
            double op = 0;
            switch (tok[i][0]) {
            case 'M': op = OP_MOVE; n = 2; break;
            case 'L': op = OP_LINE; n = 2; break;
            case 'C': op = OP_CUBIC; n = 6; break;
            case 'Z': op = OP_CLOSE; n = 0; break;
            default: continue;
            }
            g_array_append_val(l->ops, op);
            for (int k = 0; k < n && tok[i + 1]; ++k) {
                double v = g_ascii_strtod(tok[++i], NULL);
                g_array_append_val(l->ops, v);
            }
        }
        g_strfreev(tok);
        g_ptr_array_add(layers, l);
    }
    g_strfreev(parts);
    g_hash_table_replace(icons, g_strdup(name), layers);
}

/// Draw icon `name` into a square of `size` pixels at the origin.
void fw_icon_draw(cairo_t *cr, const char *name, double size, GdkRGBA ink, gboolean sensitive) {
    GPtrArray *layers = icons && name ? g_hash_table_lookup(icons, name) : NULL;
    if (!layers) return;
    double k = size / 24.0;
    GdkRGBA acc = accent;
    if (!sensitive) acc.alpha *= 0.4;
    cairo_save(cr);
    cairo_scale(cr, k, k);
    cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND);
    cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND);
    // 1.5 units on the 24 grid, never thinner than a device pixel.
    cairo_set_line_width(cr, MAX(1.5, 1.0 / k));
    for (guint i = 0; i < layers->len; ++i) {
        Layer *l = g_ptr_array_index(layers, i);
        cairo_new_path(cr);
        const double *o = (const double *)l->ops->data;
        for (guint j = 0; j < l->ops->len;) {
            switch ((int)o[j]) {
            case OP_MOVE: cairo_move_to(cr, o[j + 1], o[j + 2]); j += 3; break;
            case OP_LINE: cairo_line_to(cr, o[j + 1], o[j + 2]); j += 3; break;
            case OP_CUBIC: cairo_curve_to(cr, o[j + 1], o[j + 2], o[j + 3], o[j + 4], o[j + 5], o[j + 6]); j += 7; break;
            default: cairo_close_path(cr); j += 1; break;
            }
        }
        static const double dash[] = {2.0, 2.5};
        switch (l->paint) {
        case PAINT_FILL: gdk_cairo_set_source_rgba(cr, &ink); cairo_fill(cr); break;
        case PAINT_ACCENT_FILL:
            cairo_set_source_rgba(cr, acc.red, acc.green, acc.blue, acc.alpha * 0.22);
            cairo_fill(cr);
            break;
        case PAINT_ACCENT:
        case PAINT_ACCENT_DASHED:
            gdk_cairo_set_source_rgba(cr, &acc);
            cairo_set_dash(cr, dash, l->paint == PAINT_ACCENT_DASHED ? 2 : 0, 0);
            cairo_stroke(cr);
            break;
        default:
            gdk_cairo_set_source_rgba(cr, &ink);
            cairo_set_dash(cr, dash, l->paint == PAINT_DASHED ? 2 : 0, 0);
            cairo_stroke(cr);
            break;
        }
    }
    cairo_restore(cr);
}

static void drawIcon(GtkDrawingArea *area, cairo_t *cr, int w, int h, gpointer data) {
    (void)data;
    const char *name = g_object_get_data(G_OBJECT(area), "forge-icon");
    GdkRGBA ink;
#if GTK_CHECK_VERSION(4, 10, 0)
    gtk_widget_get_color(GTK_WIDGET(area), &ink);
#else
    gtk_style_context_get_color(gtk_widget_get_style_context(GTK_WIDGET(area)), &ink);
#endif
    if (g_object_get_data(G_OBJECT(area), "forge-icon-white")) ink = (GdkRGBA){1, 1, 1, 1};
    double size = MIN(w, h);
    cairo_translate(cr, (w - size) / 2, (h - size) / 2);
    fw_icon_draw(cr, name, size, ink, gtk_widget_is_sensitive(GTK_WIDGET(area)));
}

GtkWidget *fw_icon_widget(const char *name, int size) {
    GtkWidget *d = gtk_drawing_area_new();
    gtk_drawing_area_set_content_width(GTK_DRAWING_AREA(d), size);
    gtk_drawing_area_set_content_height(GTK_DRAWING_AREA(d), size);
    gtk_widget_set_halign(d, GTK_ALIGN_CENTER);
    gtk_widget_set_valign(d, GTK_ALIGN_CENTER);
    g_object_set_data_full(G_OBJECT(d), "forge-icon", g_strdup(name ? name : ""), g_free);
    gtk_drawing_area_set_draw_func(GTK_DRAWING_AREA(d), drawIcon, NULL, NULL);
    gtk_widget_add_css_class(d, "forge-icon");
    return d;
}

void fw_icon_widget_set_white(GtkWidget *icon) { g_object_set_data(G_OBJECT(icon), "forge-icon-white", GINT_TO_POINTER(1)); }

gboolean fw_icon_exists(const char *name) { return icons && name && g_hash_table_contains(icons, name); }
