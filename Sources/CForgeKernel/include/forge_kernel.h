/*
 * forge_kernel.h — Forge's C ABI over the geometry kernel (OCCT).
 *
 * Design rules (docs/adr/0001-kernel-wrapping.md):
 *   - No OCCT type appears in this header. Shapes and meshes are opaque handles.
 *   - Every fallible call takes an FKError* and never throws across the boundary.
 *   - Handles are immutable after creation and safe to read from multiple threads;
 *     operations that would lazily mutate OCCT state (meshing) work on a private copy.
 *   - All lengths are millimetres, all angles radians.
 *   - Topological indices (face/edge/vertex) are 0-based positions in OCCT's
 *     TopExp::MapShapes order, which is deterministic for a given shape. They are
 *     *transient* — persistent naming lives above the kernel (docs/adr/0002).
 */
#ifndef FORGE_KERNEL_H
#define FORGE_KERNEL_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct FKShape FKShape;
typedef struct FKMesh FKMesh;

enum {
    FK_OK = 0,
    FK_ERR_INVALID_ARGUMENT = 1,
    FK_ERR_CONSTRUCTION_FAILED = 2,
    FK_ERR_BOOLEAN_FAILED = 3,
    FK_ERR_IO = 4,
    FK_ERR_KERNEL_EXCEPTION = 5,
    FK_ERR_EMPTY_RESULT = 6,
    FK_ERR_OUT_OF_RANGE = 7,
};

typedef struct FKError {
    int32_t code;
    char message[512];
} FKError;

typedef enum FKBooleanOp {
    FK_BOOL_FUSE = 0,
    FK_BOOL_CUT = 1,
    FK_BOOL_COMMON = 2,
} FKBooleanOp;

typedef enum FKShapeType {
    FK_SHAPE_COMPOUND = 0,
    FK_SHAPE_COMPSOLID = 1,
    FK_SHAPE_SOLID = 2,
    FK_SHAPE_SHELL = 3,
    FK_SHAPE_FACE = 4,
    FK_SHAPE_WIRE = 5,
    FK_SHAPE_EDGE = 6,
    FK_SHAPE_VERTEX = 7,
    FK_SHAPE_EMPTY = 8,
} FKShapeType;

typedef enum FKSurfaceType {
    FK_SURF_PLANE = 0,
    FK_SURF_CYLINDER = 1,
    FK_SURF_CONE = 2,
    FK_SURF_SPHERE = 3,
    FK_SURF_TORUS = 4,
    FK_SURF_BEZIER = 5,
    FK_SURF_BSPLINE = 6,
    FK_SURF_REVOLUTION = 7,
    FK_SURF_EXTRUSION = 8,
    FK_SURF_OFFSET = 9,
    FK_SURF_OTHER = 10,
} FKSurfaceType;

typedef enum FKCurveType {
    FK_CURVE_LINE = 0,
    FK_CURVE_CIRCLE = 1,
    FK_CURVE_ELLIPSE = 2,
    FK_CURVE_HYPERBOLA = 3,
    FK_CURVE_PARABOLA = 4,
    FK_CURVE_BEZIER = 5,
    FK_CURVE_BSPLINE = 6,
    FK_CURVE_OFFSET = 7,
    FK_CURVE_OTHER = 8,
} FKCurveType;

typedef struct FKTopology {
    int32_t solids;
    int32_t shells;
    int32_t faces;
    int32_t wires;
    int32_t edges;
    int32_t vertices;
} FKTopology;

typedef struct FKMassProperties {
    double volume;          /* mm^3 */
    double surfaceArea;     /* mm^2 */
    double centroid[3];     /* volume centroid, mm (surface centroid if volume == 0) */
    double inertia[9];      /* row-major inertia tensor about centroid, unit density, mm^5 */
    double principalMoments[3];
} FKMassProperties;

typedef struct FKValidity {
    int32_t isValid;        /* BRepCheck_Analyzer */
    int32_t isClosed;       /* no free (boundary) edges in shells */
    int32_t freeEdges;      /* edges bounding exactly one face */
    int32_t isEmpty;
} FKValidity;

typedef struct FKFaceInfo {
    int32_t surfaceType;    /* FKSurfaceType */
    double area;
    double centroid[3];
    double normal[3];       /* outward normal at the parametric centre, orientation-corrected */
    int32_t edgeCount;
} FKFaceInfo;

typedef struct FKEdgeInfo {
    int32_t curveType;      /* FKCurveType */
    double length;
    double start[3];
    double end[3];
    double midpoint[3];
    int32_t isDegenerate;
    int32_t adjacentFaces;
} FKEdgeInfo;

/* ---- library ---------------------------------------------------------- */
const char *fk_kernel_version(void);    /* e.g. "OCCT 8.0.1" */

/* ---- lifetime --------------------------------------------------------- */
void fk_shape_release(FKShape *shape);
void fk_mesh_release(FKMesh *mesh);

/* ---- primitives (placement: origin + axis (Z dir) + x-direction) ------ */
FKShape *fk_make_box(const double origin[3], double dx, double dy, double dz, FKError *err);
FKShape *fk_make_cylinder(const double origin[3], const double axis[3], double radius, double height, FKError *err);
FKShape *fk_make_cone(const double origin[3], const double axis[3], double r1, double r2, double height, FKError *err);
FKShape *fk_make_sphere(const double center[3], double radius, FKError *err);
FKShape *fk_make_torus(const double origin[3], const double axis[3], double majorRadius, double minorRadius, FKError *err);

/* ---- operations -------------------------------------------------------- */
FKShape *fk_boolean(const FKShape *a, const FKShape *b, FKBooleanOp op, FKError *err);
/* m is a row-major 3x4 affine matrix [R | t]; must be a rigid motion or uniform scale. */
FKShape *fk_transform(const FKShape *shape, const double m[12], FKError *err);
FKShape *fk_fillet_edges(const FKShape *shape, const int32_t *edgeIndices, size_t count, double radius, FKError *err);

/* ---- queries ------------------------------------------------------------ */
int32_t fk_shape_type(const FKShape *shape);
int32_t fk_topology(const FKShape *shape, FKTopology *out, FKError *err);
int32_t fk_mass_properties(const FKShape *shape, FKMassProperties *out, FKError *err);
/* out = {xmin, ymin, zmin, xmax, ymax, zmax}; optimal = tight box (slower). */
int32_t fk_bounding_box(const FKShape *shape, int32_t optimal, double out[6], FKError *err);
int32_t fk_check(const FKShape *shape, FKValidity *out, FKError *err);
int32_t fk_face_info(const FKShape *shape, int32_t faceIndex, FKFaceInfo *out, FKError *err);
int32_t fk_edge_info(const FKShape *shape, int32_t edgeIndex, FKEdgeInfo *out, FKError *err);
/* Indices of the faces adjacent to an edge (up to maxOut); returns count or -1. */
int32_t fk_edge_faces(const FKShape *shape, int32_t edgeIndex, int32_t *outFaces, int32_t maxOut, FKError *err);
/* Minimum distance between two shapes; points receive the closest pair. */
int32_t fk_distance(const FKShape *a, const FKShape *b, double *outDistance, double outPointA[3], double outPointB[3], FKError *err);

/* ---- tessellation ------------------------------------------------------- */
/* linearDeflection in mm (<=0: auto from bbox), angularDeflection in radians. */
FKMesh *fk_tessellate(const FKShape *shape, double linearDeflection, double angularDeflection, FKError *err);
size_t fk_mesh_vertex_count(const FKMesh *mesh);
size_t fk_mesh_triangle_count(const FKMesh *mesh);
const float *fk_mesh_positions(const FKMesh *mesh);     /* 3 floats per vertex */
const float *fk_mesh_normals(const FKMesh *mesh);       /* 3 floats per vertex */
const uint32_t *fk_mesh_indices(const FKMesh *mesh);    /* 3 per triangle, CCW = outward */
const uint32_t *fk_mesh_triangle_faces(const FKMesh *mesh); /* face index per triangle */
size_t fk_mesh_edge_count(const FKMesh *mesh);          /* polylines, one per non-degenerate edge */
const uint32_t *fk_mesh_edge_offsets(const FKMesh *mesh); /* edge_count + 1 offsets into edge points */
const uint32_t *fk_mesh_edge_ids(const FKMesh *mesh);   /* edge index per polyline */
const float *fk_mesh_edge_points(const FKMesh *mesh);   /* 3 floats per point */

/* ---- serialization & exchange ------------------------------------------- */
/* Binary BREP (BinTools). *outData must be freed with fk_free_buffer. */
int32_t fk_write_brep(const FKShape *shape, uint8_t **outData, size_t *outSize, FKError *err);
FKShape *fk_read_brep(const uint8_t *data, size_t size, FKError *err);
void fk_free_buffer(uint8_t *data);

int32_t fk_export_step(const FKShape *const *shapes, size_t count, const char *path, FKError *err);
FKShape *fk_import_step(const char *path, FKError *err);
int32_t fk_export_stl(const FKShape *shape, const char *path, int32_t ascii, double linearDeflection, FKError *err);

#ifdef __cplusplus
}
#endif

#endif /* FORGE_KERNEL_H */
