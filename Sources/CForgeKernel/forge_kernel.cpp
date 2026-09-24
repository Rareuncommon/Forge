// forge_kernel.cpp — implementation of the C ABI in include/forge_kernel.h over OCCT.
// Compiles against OCCT 7.6 (Ubuntu 24.04 packages, Linux CI) and OCCT 8.0.x (macOS build).
// No exception may escape an extern "C" function.

#include "forge_kernel.h"

#include <BRepAdaptor_Curve.hxx>
#include <BRepAdaptor_Surface.hxx>
#include <BRepAlgoAPI_BooleanOperation.hxx>
#include <BRepAlgoAPI_Common.hxx>
#include <BRepAlgoAPI_Cut.hxx>
#include <BRepAlgoAPI_Fuse.hxx>
#include <BRepBndLib.hxx>
#include <BRepBuilderAPI_Copy.hxx>
#include <BRepBuilderAPI_Transform.hxx>
#include <BRepCheck_Analyzer.hxx>
#include <BRepExtrema_DistShapeShape.hxx>
#include <BRepFilletAPI_MakeFillet.hxx>
#include <BRepFilletAPI_MakeChamfer.hxx>
#include <BRepOffsetAPI_DraftAngle.hxx>
#include <BRepOffsetAPI_MakeOffset.hxx>
#include <BRepOffsetAPI_MakeThickSolid.hxx>
#include <BRepOffsetAPI_MakeOffsetShape.hxx>
#include <BRepLib_FindSurface.hxx>
#include <Geom_Plane.hxx>
#include <gp_Pln.hxx>
#include <BRepGProp.hxx>
#include <BRepMesh_IncrementalMesh.hxx>
#include <BRepPrimAPI_MakeBox.hxx>
#include <BRepPrimAPI_MakeCone.hxx>
#include <BRepPrimAPI_MakeCylinder.hxx>
#include <BRepPrimAPI_MakeSphere.hxx>
#include <BRepPrimAPI_MakeTorus.hxx>
#include <BRepTools.hxx>
#include <BRep_Tool.hxx>
#include <BinTools.hxx>
#include <Bnd_Box.hxx>
#include <GCPnts_AbscissaPoint.hxx>
#include <GCPnts_TangentialDeflection.hxx>
#include <GProp_GProps.hxx>
#include <GProp_PrincipalProps.hxx>
#include <IFSelect_ReturnStatus.hxx>
#include <Interface_Static.hxx>
#include <Message_ProgressRange.hxx>
#include <Poly_Triangulation.hxx>
#include <STEPControl_Reader.hxx>
#include <STEPControl_Writer.hxx>
#include <ShapeUpgrade_UnifySameDomain.hxx>
#include <Standard_Failure.hxx>
#include <Standard_Version.hxx>
#include <StlAPI_Writer.hxx>
#include <TopExp.hxx>
#include <TopExp_Explorer.hxx>
#include <TopLoc_Location.hxx>
#include <TopTools_IndexedDataMapOfShapeListOfShape.hxx>
#include <TopTools_IndexedMapOfShape.hxx>
#include <TopTools_ListOfShape.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Compound.hxx>
#include <TopoDS_Edge.hxx>
#include <TopoDS_Face.hxx>
#include <TopoDS_Shape.hxx>
#include <BRep_Builder.hxx>
#include <BRepBuilderAPI_MakeEdge.hxx>
#include <BRepBuilderAPI_MakeFace.hxx>
#include <BRepBuilderAPI_MakeWire.hxx>
#include <BRepPrimAPI_MakePrism.hxx>
#include <BRepPrimAPI_MakeRevol.hxx>
#include <GC_MakeArcOfCircle.hxx>
#include <GC_MakeArcOfEllipse.hxx>
#include <Geom_BSplineCurve.hxx>
#include <TColStd_Array1OfInteger.hxx>
#include <TColStd_Array1OfReal.hxx>
#include <TColgp_Array1OfPnt.hxx>
#include <Geom_TrimmedCurve.hxx>
#include <ShapeFix_Face.hxx>
#include <ShapeFix_Shape.hxx>
#include <gp_Circ.hxx>
#include <gp_Elips.hxx>
#include <gp_Ax2.hxx>
#include <gp_Trsf.hxx>

#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <cstring>
#include <memory>
#include <mutex>
#include <sstream>
#include <string>
#include <vector>

struct FKShape {
    TopoDS_Shape shape;
};

struct FKMesh {
    std::vector<float> positions;
    std::vector<float> normals;
    std::vector<uint32_t> indices;
    std::vector<uint32_t> triangleFaces;
    std::vector<uint32_t> edgeOffsets{0};
    std::vector<uint32_t> edgeIds;
    std::vector<float> edgePoints;
};

namespace {

// OCCT's data-exchange layer keeps global static parameters; serialise access.
std::mutex &dataExchangeMutex() {
    static std::mutex m;
    return m;
}

void setError(FKError *err, int32_t code, const char *message) {
    if (!err) return;
    err->code = code;
    std::snprintf(err->message, sizeof(err->message), "%s", message ? message : "");
}

void clearError(FKError *err) {
    if (!err) return;
    err->code = FK_OK;
    err->message[0] = '\0';
}

FKShape *wrap(const TopoDS_Shape &s) { return new FKShape{s}; }

bool finite3(const double v[3]) {
    return v && std::isfinite(v[0]) && std::isfinite(v[1]) && std::isfinite(v[2]);
}

bool validAxis(const double v[3]) {
    return finite3(v) && (v[0] * v[0] + v[1] * v[1] + v[2] * v[2]) > 1e-20;
}

bool positive(double v) { return std::isfinite(v) && v > 0.0; }

TopoDS_Shape unify(const TopoDS_Shape &shape) {
    // Merge coplanar/co-cylindrical faces and collinear edges produced by booleans, so that
    // topology matches user expectation (a fused pair of flush boxes is one box).
    ShapeUpgrade_UnifySameDomain unifier(shape, Standard_True, Standard_True, Standard_True);
    unifier.Build();
    return unifier.Shape();
}

double autoDeflection(const TopoDS_Shape &shape) {
    Bnd_Box box;
    BRepBndLib::Add(shape, box);
    if (box.IsVoid()) return 0.1;
    double x0, y0, z0, x1, y1, z1;
    box.Get(x0, y0, z0, x1, y1, z1);
    double diag = std::sqrt((x1 - x0) * (x1 - x0) + (y1 - y0) * (y1 - y0) + (z1 - z0) * (z1 - z0));
    return std::max(diag * 0.001, 0.001);
}

bool hasShape(const FKShape *s, FKError *err) {
    if (!s) {
        setError(err, FK_ERR_INVALID_ARGUMENT, "null shape handle");
        return false;
    }
    return true;
}

int32_t surfaceType(GeomAbs_SurfaceType t) {
    switch (t) {
    case GeomAbs_Plane: return FK_SURF_PLANE;
    case GeomAbs_Cylinder: return FK_SURF_CYLINDER;
    case GeomAbs_Cone: return FK_SURF_CONE;
    case GeomAbs_Sphere: return FK_SURF_SPHERE;
    case GeomAbs_Torus: return FK_SURF_TORUS;
    case GeomAbs_BezierSurface: return FK_SURF_BEZIER;
    case GeomAbs_BSplineSurface: return FK_SURF_BSPLINE;
    case GeomAbs_SurfaceOfRevolution: return FK_SURF_REVOLUTION;
    case GeomAbs_SurfaceOfExtrusion: return FK_SURF_EXTRUSION;
    case GeomAbs_OffsetSurface: return FK_SURF_OFFSET;
    default: return FK_SURF_OTHER;
    }
}

int32_t curveType(GeomAbs_CurveType t) {
    switch (t) {
    case GeomAbs_Line: return FK_CURVE_LINE;
    case GeomAbs_Circle: return FK_CURVE_CIRCLE;
    case GeomAbs_Ellipse: return FK_CURVE_ELLIPSE;
    case GeomAbs_Hyperbola: return FK_CURVE_HYPERBOLA;
    case GeomAbs_Parabola: return FK_CURVE_PARABOLA;
    case GeomAbs_BezierCurve: return FK_CURVE_BEZIER;
    case GeomAbs_BSplineCurve: return FK_CURVE_BSPLINE;
    case GeomAbs_OffsetCurve: return FK_CURVE_OFFSET;
    default: return FK_CURVE_OTHER;
    }
}

void put3(double out[3], const gp_XYZ &p) {
    out[0] = p.X();
    out[1] = p.Y();
    out[2] = p.Z();
}

// Outward unit normal of a face at (u, v); returns false at singular points.
bool faceNormal(const BRepAdaptor_Surface &surf, const TopoDS_Face &face, double u, double v, gp_Vec &n) {
    gp_Pnt p;
    gp_Vec du, dv;
    surf.D1(u, v, p, du, dv);
    n = du.Crossed(dv);
    if (n.Magnitude() < 1e-12) return false;
    n.Normalize();
    if (face.Orientation() == TopAbs_REVERSED) n.Reverse();
    return true;
}

gp_Ax2 placement(const double origin[3], const double axis[3]) {
    return gp_Ax2(gp_Pnt(origin[0], origin[1], origin[2]), gp_Dir(axis[0], axis[1], axis[2]));
}

// OCCT 8 made Standard_Failure a std::exception with ExceptionType(); OCCT 7 derives it from
// Standard_Transient with DynamicType() and GetMessageString().
std::string failureDescription(const Standard_Failure &e) {
#if OCC_VERSION_HEX >= 0x080000
    return std::string(e.ExceptionType()) + ": " + (e.what() ? e.what() : "");
#else
    return std::string(e.DynamicType()->Name()) + ": " + (e.GetMessageString() ? e.GetMessageString() : "");
#endif
}

} // namespace

#define FK_BEGIN try {
#define FK_END(ret)                                                                                \
    }                                                                                              \
    catch (const Standard_Failure &e) {                                                            \
        std::string m = failureDescription(e);                                                     \
        setError(err, FK_ERR_KERNEL_EXCEPTION, m.c_str());                                         \
        return ret;                                                                                \
    }                                                                                              \
    catch (const std::exception &e) {                                                              \
        setError(err, FK_ERR_KERNEL_EXCEPTION, e.what());                                          \
        return ret;                                                                                \
    }                                                                                              \
    catch (...) {                                                                                  \
        setError(err, FK_ERR_KERNEL_EXCEPTION, "unknown kernel exception");                        \
        return ret;                                                                                \
    }

extern "C" {

const char *fk_kernel_version(void) {
    static const std::string v = std::string("OCCT ") + OCC_VERSION_COMPLETE;
    return v.c_str();
}

void fk_shape_release(FKShape *shape) { delete shape; }
void fk_mesh_release(FKMesh *mesh) { delete mesh; }
void fk_free_buffer(uint8_t *data) { std::free(data); }

// ---- primitives -------------------------------------------------------------

FKShape *fk_make_box(const double origin[3], double dx, double dy, double dz, FKError *err) {
    clearError(err);
    if (!finite3(origin) || !positive(dx) || !positive(dy) || !positive(dz)) {
        setError(err, FK_ERR_INVALID_ARGUMENT, "box dimensions must be positive and finite");
        return nullptr;
    }
    FK_BEGIN
    BRepPrimAPI_MakeBox mk(gp_Pnt(origin[0], origin[1], origin[2]), dx, dy, dz);
    return wrap(mk.Shape());
    FK_END(nullptr)
}

FKShape *fk_make_cylinder(const double origin[3], const double axis[3], double radius, double height, FKError *err) {
    clearError(err);
    if (!finite3(origin) || !validAxis(axis) || !positive(radius) || !positive(height)) {
        setError(err, FK_ERR_INVALID_ARGUMENT, "cylinder needs a finite origin, non-zero axis, positive radius and height");
        return nullptr;
    }
    FK_BEGIN
    BRepPrimAPI_MakeCylinder mk(placement(origin, axis), radius, height);
    return wrap(mk.Shape());
    FK_END(nullptr)
}

FKShape *fk_make_cone(const double origin[3], const double axis[3], double r1, double r2, double height, FKError *err) {
    clearError(err);
    if (!finite3(origin) || !validAxis(axis) || !std::isfinite(r1) || !std::isfinite(r2) || r1 < 0 || r2 < 0 ||
        (r1 == 0 && r2 == 0) || std::fabs(r1 - r2) < 1e-12 || !positive(height)) {
        setError(err, FK_ERR_INVALID_ARGUMENT, "cone needs radii >= 0 (not both zero, not equal) and positive height");
        return nullptr;
    }
    FK_BEGIN
    BRepPrimAPI_MakeCone mk(placement(origin, axis), r1, r2, height);
    return wrap(mk.Shape());
    FK_END(nullptr)
}

FKShape *fk_make_sphere(const double center[3], double radius, FKError *err) {
    clearError(err);
    if (!finite3(center) || !positive(radius)) {
        setError(err, FK_ERR_INVALID_ARGUMENT, "sphere needs a finite centre and positive radius");
        return nullptr;
    }
    FK_BEGIN
    BRepPrimAPI_MakeSphere mk(gp_Pnt(center[0], center[1], center[2]), radius);
    return wrap(mk.Shape());
    FK_END(nullptr)
}

FKShape *fk_make_torus(const double origin[3], const double axis[3], double majorRadius, double minorRadius, FKError *err) {
    clearError(err);
    if (!finite3(origin) || !validAxis(axis) || !positive(majorRadius) || !positive(minorRadius) ||
        minorRadius >= majorRadius) {
        setError(err, FK_ERR_INVALID_ARGUMENT, "torus needs 0 < minor radius < major radius");
        return nullptr;
    }
    FK_BEGIN
    BRepPrimAPI_MakeTorus mk(placement(origin, axis), majorRadius, minorRadius);
    return wrap(mk.Shape());
    FK_END(nullptr)
}

// ---- operations -------------------------------------------------------------

FKShape *fk_boolean(const FKShape *a, const FKShape *b, FKBooleanOp op, FKError *err) {
    clearError(err);
    if (!hasShape(a, err) || !hasShape(b, err)) return nullptr;
    FK_BEGIN
    TopTools_ListOfShape args, tools;
    args.Append(a->shape);
    tools.Append(b->shape);
    std::unique_ptr<BRepAlgoAPI_BooleanOperation> alg;
    switch (op) {
    case FK_BOOL_FUSE: alg = std::make_unique<BRepAlgoAPI_Fuse>(); break;
    case FK_BOOL_CUT: alg = std::make_unique<BRepAlgoAPI_Cut>(); break;
    case FK_BOOL_COMMON: alg = std::make_unique<BRepAlgoAPI_Common>(); break;
    default:
        setError(err, FK_ERR_INVALID_ARGUMENT, "unknown boolean operation");
        return nullptr;
    }
    alg->SetArguments(args);
    alg->SetTools(tools);
    alg->SetRunParallel(Standard_False); // deterministic regeneration (docs/adr/0002)
    alg->Build();
    if (!alg->IsDone() || alg->HasErrors()) {
        std::ostringstream ss;
        alg->DumpErrors(ss);
        std::string m = "boolean operation failed";
        if (!ss.str().empty()) m += ": " + ss.str();
        setError(err, FK_ERR_BOOLEAN_FAILED, m.c_str());
        return nullptr;
    }
    TopoDS_Shape result = unify(alg->Shape());
    TopTools_IndexedMapOfShape solids;
    TopExp::MapShapes(result, TopAbs_SOLID, solids);
    TopTools_IndexedMapOfShape faces;
    TopExp::MapShapes(result, TopAbs_FACE, faces);
    if (faces.Extent() == 0) {
        setError(err, FK_ERR_EMPTY_RESULT, "boolean operation produced an empty result (bodies do not overlap?)");
        return nullptr;
    }
    // A single solid is returned bare rather than wrapped in a compound.
    if (solids.Extent() == 1) result = solids(1);
    return wrap(result);
    FK_END(nullptr)
}

FKShape *fk_transform(const FKShape *shape, const double m[12], FKError *err) {
    clearError(err);
    if (!hasShape(shape, err)) return nullptr;
    for (int i = 0; i < 12; ++i) {
        if (!std::isfinite(m[i])) {
            setError(err, FK_ERR_INVALID_ARGUMENT, "transform matrix must be finite");
            return nullptr;
        }
    }
    FK_BEGIN
    gp_Trsf t;
    t.SetValues(m[0], m[1], m[2], m[3], m[4], m[5], m[6], m[7], m[8], m[9], m[10], m[11]);
    BRepBuilderAPI_Transform tr(shape->shape, t, Standard_True);
    return wrap(tr.Shape());
    FK_END(nullptr)
}

FKShape *fk_fillet_edges(const FKShape *shape, const int32_t *edgeIndices, size_t count, double radius, FKError *err) {
    clearError(err);
    if (!hasShape(shape, err)) return nullptr;
    if (!positive(radius) || count == 0 || !edgeIndices) {
        setError(err, FK_ERR_INVALID_ARGUMENT, "fillet needs a positive radius and at least one edge");
        return nullptr;
    }
    FK_BEGIN
    TopTools_IndexedMapOfShape edges;
    TopExp::MapShapes(shape->shape, TopAbs_EDGE, edges);
    BRepFilletAPI_MakeFillet mk(shape->shape);
    for (size_t i = 0; i < count; ++i) {
        int32_t idx = edgeIndices[i];
        if (idx < 0 || idx >= edges.Extent()) {
            setError(err, FK_ERR_OUT_OF_RANGE, "edge index out of range");
            return nullptr;
        }
        mk.Add(radius, TopoDS::Edge(edges(idx + 1)));
    }
    mk.Build();
    if (!mk.IsDone()) {
        setError(err, FK_ERR_CONSTRUCTION_FAILED, "fillet failed (radius too large for adjacent faces?)");
        return nullptr;
    }
    return wrap(mk.Shape());
    FK_END(nullptr)
}

namespace {
double volumeOf(const TopoDS_Shape &s) {
    GProp_GProps g;
    BRepGProp::VolumeProperties(s, g);
    return g.Mass();
}

bool collect(const TopoDS_Shape &shape, TopAbs_ShapeEnum kind, const int32_t *idx, size_t count, TopTools_ListOfShape &out,
             FKError *err) {
    TopTools_IndexedMapOfShape map;
    TopExp::MapShapes(shape, kind, map);
    for (size_t i = 0; i < count; ++i) {
        if (idx[i] < 0 || idx[i] >= map.Extent()) {
            setError(err, FK_ERR_OUT_OF_RANGE, kind == TopAbs_FACE ? "face index out of range" : "edge index out of range");
            return false;
        }
        out.Append(map(idx[i] + 1));
    }
    return true;
}

/* Draft `faces` of `shape`; returns a null shape on failure. */
TopoDS_Shape draft(const TopoDS_Shape &shape, const TopTools_ListOfShape &faces, const gp_Dir &dir, double angle, const gp_Pln &neutral) {
    BRepOffsetAPI_DraftAngle mk(shape);
    for (TopTools_ListIteratorOfListOfShape it(faces); it.More(); it.Next()) {
        mk.Add(TopoDS::Face(it.Value()), dir, angle, neutral);
        if (!mk.AddDone()) return TopoDS_Shape();
    }
    mk.Build();
    if (!mk.IsDone()) return TopoDS_Shape();
    return mk.Shape();
}

/* Draft with the sign that makes the solid lose volume (inward) or gain it (outward). */
TopoDS_Shape draftInOrOut(const TopoDS_Shape &shape, const TopTools_ListOfShape &faces, const gp_Dir &dir, double angle, const gp_Pln &neutral,
                          bool outward) {
    const double base = volumeOf(shape);
    for (double sign : {1.0, -1.0}) {
        TopoDS_Shape r = draft(shape, faces, dir, sign * angle, neutral);
        if (r.IsNull()) continue;
        const double v = volumeOf(r);
        if ((outward && v > base) || (!outward && v < base)) return r;
    }
    return TopoDS_Shape();
}
} // namespace

FKShape *fk_chamfer_edges(const FKShape *shape, const int32_t *edgeIndices, size_t count, double distance, double distance2,
                          double angle, FKError *err) {
    clearError(err);
    if (!hasShape(shape, err)) return nullptr;
    if (!positive(distance) || count == 0 || !edgeIndices) {
        setError(err, FK_ERR_INVALID_ARGUMENT, "chamfer needs a positive distance and at least one edge");
        return nullptr;
    }
    FK_BEGIN
    TopTools_ListOfShape edges;
    if (!collect(shape->shape, TopAbs_EDGE, edgeIndices, count, edges, err)) return nullptr;
    TopTools_IndexedDataMapOfShapeListOfShape edgeFaces;
    TopExp::MapShapesAndAncestors(shape->shape, TopAbs_EDGE, TopAbs_FACE, edgeFaces);
    BRepFilletAPI_MakeChamfer mk(shape->shape);
    for (TopTools_ListIteratorOfListOfShape it(edges); it.More(); it.Next()) {
        const TopoDS_Edge &e = TopoDS::Edge(it.Value());
        if (distance2 <= 0 && angle <= 0) {
            mk.Add(distance, e);
            continue;
        }
        const TopTools_ListOfShape &faces = edgeFaces.FindFromKey(e);
        if (faces.IsEmpty()) {
            setError(err, FK_ERR_CONSTRUCTION_FAILED, "edge has no adjacent face");
            return nullptr;
        }
        const TopoDS_Face &f = TopoDS::Face(faces.First());
        if (angle > 0) mk.AddDA(distance, angle, e, f);
        else mk.Add(distance, distance2, e, f);
    }
    mk.Build();
    if (!mk.IsDone()) {
        setError(err, FK_ERR_CONSTRUCTION_FAILED, "chamfer failed (distance too large for the adjacent faces?)");
        return nullptr;
    }
    return wrap(mk.Shape());
    FK_END(nullptr)
}

FKShape *fk_shell(const FKShape *shape, const int32_t *faceIndices, size_t count, double thickness, int32_t outward, FKError *err) {
    clearError(err);
    if (!hasShape(shape, err)) return nullptr;
    if (!positive(thickness)) {
        setError(err, FK_ERR_INVALID_ARGUMENT, "shell needs a positive thickness");
        return nullptr;
    }
    FK_BEGIN
    TopTools_ListOfShape faces;
    if (count > 0 && !collect(shape->shape, TopAbs_FACE, faceIndices, count, faces, err)) return nullptr;
    const double offset = outward ? thickness : -thickness;
    if (count == 0) {
        // Closed hollow body: offset the whole solid and subtract (sharp corners, as SolidWorks).
        BRepOffsetAPI_MakeOffsetShape off;
        off.PerformByJoin(shape->shape, offset, 1.0e-3, BRepOffset_Skin, Standard_False, Standard_False, GeomAbs_Intersection);
        if (!off.IsDone() || off.Shape().IsNull()) {
            setError(err, FK_ERR_CONSTRUCTION_FAILED, "shell failed (thickness larger than a wall or a radius of curvature?)");
            return nullptr;
        }
        BRepAlgoAPI_Cut cut(outward ? off.Shape() : shape->shape, outward ? shape->shape : off.Shape());
        if (!cut.IsDone()) {
            setError(err, FK_ERR_CONSTRUCTION_FAILED, "shell failed");
            return nullptr;
        }
        return wrap(cut.Shape());
    }
    BRepOffsetAPI_MakeThickSolid mk;
    mk.MakeThickSolidByJoin(shape->shape, faces, offset, 1.0e-3, BRepOffset_Skin, Standard_False, Standard_False, GeomAbs_Intersection);
    mk.Build();
    if (!mk.IsDone() || mk.Shape().IsNull()) {
        setError(err, FK_ERR_CONSTRUCTION_FAILED, "shell failed (thickness larger than a radius of curvature or a wall?)");
        return nullptr;
    }
    return wrap(mk.Shape());
    FK_END(nullptr)
}

FKShape *fk_draft_faces(const FKShape *shape, const int32_t *faceIndices, size_t count, const double planeOrigin[3],
                        const double pullDirection[3], double angle, int32_t outward, FKError *err) {
    clearError(err);
    if (!hasShape(shape, err)) return nullptr;
    if (!(angle > 0 && angle < M_PI / 2) || count == 0 || !faceIndices) {
        setError(err, FK_ERR_INVALID_ARGUMENT, "draft needs an angle between 0 and 90 degrees and at least one face");
        return nullptr;
    }
    FK_BEGIN
    TopTools_ListOfShape faces;
    if (!collect(shape->shape, TopAbs_FACE, faceIndices, count, faces, err)) return nullptr;
    const gp_Dir dir(pullDirection[0], pullDirection[1], pullDirection[2]);
    const gp_Pln neutral(gp_Pnt(planeOrigin[0], planeOrigin[1], planeOrigin[2]), dir);
    TopoDS_Shape r = draftInOrOut(shape->shape, faces, dir, angle, neutral, outward != 0);
    if (r.IsNull()) {
        setError(err, FK_ERR_CONSTRUCTION_FAILED, "draft failed (faces must meet the neutral plane or be parallel to the pull direction)");
        return nullptr;
    }
    return wrap(r);
    FK_END(nullptr)
}

FKShape *fk_extrude_draft(const FKShape *profile, const double v[3], double angle, int32_t outward, FKError *err) {
    clearError(err);
    if (!hasShape(profile, err)) return nullptr;
    const gp_Vec vec(v[0], v[1], v[2]);
    if (vec.Magnitude() <= 0 || !(angle > 0 && angle < M_PI / 2)) {
        setError(err, FK_ERR_INVALID_ARGUMENT, "drafted extrusion needs a direction and an angle between 0 and 90 degrees");
        return nullptr;
    }
    FK_BEGIN
    BRepPrimAPI_MakePrism prism(profile->shape, vec, Standard_True);
    prism.Build();
    if (!prism.IsDone()) {
        setError(err, FK_ERR_CONSTRUCTION_FAILED, "extrusion failed");
        return nullptr;
    }
    const TopoDS_Shape solid = prism.Shape();
    // Side faces: every face except the two caps (the profile and its translate).
    TopTools_IndexedMapOfShape capFaces;
    TopExp::MapShapes(prism.FirstShape(), TopAbs_FACE, capFaces);
    TopExp::MapShapes(prism.LastShape(), TopAbs_FACE, capFaces);
    TopTools_ListOfShape sides;
    for (TopExp_Explorer ex(solid, TopAbs_FACE); ex.More(); ex.Next()) {
        if (!capFaces.Contains(ex.Current())) sides.Append(ex.Current());
    }
    Handle(Geom_Surface) surf = BRepLib_FindSurface(profile->shape, 1e-6, Standard_True).Surface();
    Handle(Geom_Plane) plane = Handle(Geom_Plane)::DownCast(surf);
    if (plane.IsNull()) {
        setError(err, FK_ERR_INVALID_ARGUMENT, "drafted extrusion needs a planar profile");
        return nullptr;
    }
    const gp_Dir dir(vec);
    const gp_Pln neutral(plane->Pln().Location(), dir);
    TopoDS_Shape r = draftInOrOut(solid, sides, dir, angle, neutral, outward != 0);
    if (r.IsNull()) {
        setError(err, FK_ERR_CONSTRUCTION_FAILED, "draft failed (angle too large for the depth?)");
        return nullptr;
    }
    return wrap(r);
    FK_END(nullptr)
}

FKShape *fk_offset_face(const FKShape *face, double distance, FKError *err) {
    clearError(err);
    if (!hasShape(face, err)) return nullptr;
    TopExp_Explorer fx(face->shape, TopAbs_FACE);
    if (!fx.More()) {
        setError(err, FK_ERR_INVALID_ARGUMENT, "offset needs a face");
        return nullptr;
    }
    if (distance == 0) return wrap(face->shape);
    FK_BEGIN
    TopoDS_Compound out;
    BRep_Builder bb;
    bb.MakeCompound(out);
    int made = 0;
    for (; fx.More(); fx.Next()) {
        const TopoDS_Face f = TopoDS::Face(fx.Current());
        BRepOffsetAPI_MakeOffset mk(f, GeomAbs_Arc);
        mk.Perform(distance);
        if (!mk.IsDone()) {
            setError(err, FK_ERR_CONSTRUCTION_FAILED, "offset failed");
            return nullptr;
        }
        // The offset wires: the largest encloses the others (holes).
        std::vector<TopoDS_Wire> wires;
        for (TopExp_Explorer wx(mk.Shape(), TopAbs_WIRE); wx.More(); wx.Next()) wires.push_back(TopoDS::Wire(wx.Current()));
        if (wires.empty()) continue;  // the face vanished (shrunk away)
        Handle(Geom_Surface) surf = BRep_Tool::Surface(f);
        auto area = [&](const TopoDS_Wire &w) {
            BRepBuilderAPI_MakeFace m(surf, w, Standard_True);
            if (!m.IsDone()) return 0.0;
            GProp_GProps g;
            BRepGProp::SurfaceProperties(m.Face(), g);
            return std::abs(g.Mass());
        };
        size_t outer = 0;
        double best = -1;
        for (size_t i = 0; i < wires.size(); ++i) {
            double a = area(wires[i]);
            if (a > best) { best = a; outer = i; }
        }
        BRepBuilderAPI_MakeFace mf(surf, wires[outer], Standard_True);
        for (size_t i = 0; i < wires.size(); ++i) {
            if (i != outer) mf.Add(TopoDS::Wire(wires[i].Reversed()));
        }
        if (!mf.IsDone()) continue;
        ShapeFix_Face fix(mf.Face());
        fix.Perform();
        bb.Add(out, fix.Face());
        ++made;
    }
    if (made == 0) {
        setError(err, FK_ERR_CONSTRUCTION_FAILED, "the offset removes the whole profile");
        return nullptr;
    }
    return wrap(made == 1 ? TopoDS_Shape(TopExp_Explorer(out, TopAbs_FACE).Current()) : TopoDS_Shape(out));
    FK_END(nullptr)
}

// ---- profiles → solids ----------------------------------------------------------

FKShape *fk_make_faces(const FKSegment *segments, const int32_t *loopStart, const int32_t *regionOf, size_t loopCount,
                       const double *poles, size_t poleCount, FKError *err) {
    clearError(err);
    if (!segments || !loopStart || !regionOf || loopCount == 0) {
        setError(err, FK_ERR_INVALID_ARGUMENT, "no profile loops");
        return nullptr;
    }
    FK_BEGIN
    auto pnt = [](const double *v) { return gp_Pnt(v[0], v[1], v[2]); };
    std::vector<TopoDS_Wire> wires;
    for (size_t li = 0; li < loopCount; ++li) {
        BRepBuilderAPI_MakeWire mw;
        for (int32_t si = loopStart[li]; si < loopStart[li + 1]; ++si) {
            const FKSegment &sg = segments[si];
            TopoDS_Edge e;
            switch (sg.kind) {
            case FK_SEG_LINE:
                e = BRepBuilderAPI_MakeEdge(pnt(sg.p), pnt(sg.p + 3));
                break;
            case FK_SEG_ARC: {
                GC_MakeArcOfCircle arc(pnt(sg.p), pnt(sg.p + 3), pnt(sg.p + 6));
                if (!arc.IsDone()) {
                    setError(err, FK_ERR_CONSTRUCTION_FAILED, "degenerate arc in profile");
                    return nullptr;
                }
                e = BRepBuilderAPI_MakeEdge(arc.Value());
                break;
            }
            case FK_SEG_CIRCLE: {
                gp_Circ c(gp_Ax2(pnt(sg.p), gp_Dir(sg.p[3], sg.p[4], sg.p[5])), sg.p[9]);
                e = BRepBuilderAPI_MakeEdge(c);
                break;
            }
            case FK_SEG_ELLIPSE: {
                gp_Ax2 ax(pnt(sg.p), gp_Dir(sg.p[3], sg.p[4], sg.p[5]), gp_Dir(sg.p[6], sg.p[7], sg.p[8]));
                e = BRepBuilderAPI_MakeEdge(gp_Elips(ax, sg.p[9], sg.p[10]));
                break;
            }
            case FK_SEG_ELLIPSE_ARC: {
                gp_Ax2 ax(pnt(sg.p), gp_Dir(sg.p[3], sg.p[4], sg.p[5]), gp_Dir(sg.p[6], sg.p[7], sg.p[8]));
                GC_MakeArcOfEllipse arc(gp_Elips(ax, sg.p[9], sg.p[10]), sg.p[11], sg.p[12], Standard_True);
                if (!arc.IsDone()) {
                    setError(err, FK_ERR_CONSTRUCTION_FAILED, "degenerate elliptical arc in profile");
                    return nullptr;
                }
                e = BRepBuilderAPI_MakeEdge(arc.Value());
                break;
            }
            case FK_SEG_BSPLINE: {
                const int first = (int)sg.p[0], count = (int)sg.p[1], degree = (int)sg.p[2];
                if (!poles || first < 0 || count < 2 || degree < 1 || degree >= count || (size_t)(first + count) > poleCount) {
                    setError(err, FK_ERR_INVALID_ARGUMENT, "invalid B-spline segment");
                    return nullptr;
                }
                // Clamped uniform knots: end multiplicity degree+1, interior knots simple.
                const int spans = count - degree;
                TColgp_Array1OfPnt P(1, count);
                for (int i = 0; i < count; ++i) P.SetValue(i + 1, pnt(poles + 3 * (first + i)));
                TColStd_Array1OfReal K(1, spans + 1);
                TColStd_Array1OfInteger M(1, spans + 1);
                for (int i = 0; i <= spans; ++i) {
                    K.SetValue(i + 1, (double)i / spans);
                    M.SetValue(i + 1, (i == 0 || i == spans) ? degree + 1 : 1);
                }
                Handle(Geom_BSplineCurve) c = new Geom_BSplineCurve(P, K, M, degree);
                e = BRepBuilderAPI_MakeEdge(c);
                break;
            }
            default:
                setError(err, FK_ERR_INVALID_ARGUMENT, "unknown segment kind");
                return nullptr;
            }
            mw.Add(e);
            if (!mw.IsDone()) {
                setError(err, FK_ERR_CONSTRUCTION_FAILED, "profile loop is not connected");
                return nullptr;
            }
        }
        wires.push_back(mw.Wire());
    }
    std::vector<TopoDS_Shape> faces;
    for (size_t li = 0; li < loopCount;) {
        const int32_t region = regionOf[li];
        BRepBuilderAPI_MakeFace mf(wires[li], Standard_True);
        if (!mf.IsDone()) {
            setError(err, FK_ERR_CONSTRUCTION_FAILED, "profile loop is not planar or not closed");
            return nullptr;
        }
        size_t lj = li + 1;
        for (; lj < loopCount && regionOf[lj] == region; ++lj) mf.Add(TopoDS::Wire(wires[lj].Reversed()));
        // Let ShapeFix orient outer/inner wires consistently whatever the input winding.
        ShapeFix_Face fix(mf.Face());
        fix.FixOrientation();
        fix.Perform();
        faces.push_back(fix.Face());
        li = lj;
    }
    if (faces.size() == 1) return wrap(faces[0]);
    BRep_Builder b;
    TopoDS_Compound comp;
    b.MakeCompound(comp);
    for (auto &f : faces) b.Add(comp, f);
    return wrap(comp);
    FK_END(nullptr)
}

FKShape *fk_extrude(const FKShape *profile, const double v[3], FKError *err) {
    clearError(err);
    if (!hasShape(profile, err)) return nullptr;
    if (!validAxis(v)) {
        setError(err, FK_ERR_INVALID_ARGUMENT, "extrusion vector must be non-zero");
        return nullptr;
    }
    FK_BEGIN
    BRepPrimAPI_MakePrism mk(profile->shape, gp_Vec(v[0], v[1], v[2]), Standard_True);
    TopoDS_Shape s = mk.Shape();
    TopTools_IndexedMapOfShape solids;
    TopExp::MapShapes(s, TopAbs_SOLID, solids);
    if (solids.Extent() == 1) s = solids(1);
    return wrap(s);
    FK_END(nullptr)
}

FKShape *fk_revolve(const FKShape *profile, const double origin[3], const double axis[3], double angle, FKError *err) {
    clearError(err);
    if (!hasShape(profile, err)) return nullptr;
    if (!finite3(origin) || !validAxis(axis) || !(angle > 0) || angle > 2 * M_PI + 1e-12) {
        setError(err, FK_ERR_INVALID_ARGUMENT, "revolve needs a finite axis and 0 < angle <= 360 degrees");
        return nullptr;
    }
    FK_BEGIN
    gp_Ax1 ax(gp_Pnt(origin[0], origin[1], origin[2]), gp_Dir(axis[0], axis[1], axis[2]));
    BRepPrimAPI_MakeRevol mk(profile->shape, ax, std::min(angle, 2 * M_PI), Standard_True);
    if (!mk.IsDone()) {
        setError(err, FK_ERR_CONSTRUCTION_FAILED, "revolve failed (does the profile cross the axis?)");
        return nullptr;
    }
    TopoDS_Shape s = mk.Shape();
    TopTools_IndexedMapOfShape solids;
    TopExp::MapShapes(s, TopAbs_SOLID, solids);
    if (solids.Extent() == 1) s = solids(1);
    return wrap(s);
    FK_END(nullptr)
}

// ---- queries ---------------------------------------------------------------

int32_t fk_shape_type(const FKShape *shape) {
    if (!shape || shape->shape.IsNull()) return FK_SHAPE_EMPTY;
    return static_cast<int32_t>(shape->shape.ShapeType());
}

int32_t fk_topology(const FKShape *shape, FKTopology *out, FKError *err) {
    clearError(err);
    if (!hasShape(shape, err) || !out) return FK_ERR_INVALID_ARGUMENT;
    FK_BEGIN
    auto count = [&](TopAbs_ShapeEnum t) {
        TopTools_IndexedMapOfShape m;
        TopExp::MapShapes(shape->shape, t, m);
        return static_cast<int32_t>(m.Extent());
    };
    out->solids = count(TopAbs_SOLID);
    out->shells = count(TopAbs_SHELL);
    out->faces = count(TopAbs_FACE);
    out->wires = count(TopAbs_WIRE);
    out->edges = count(TopAbs_EDGE);
    out->vertices = count(TopAbs_VERTEX);
    return FK_OK;
    FK_END(FK_ERR_KERNEL_EXCEPTION)
}

int32_t fk_mass_properties(const FKShape *shape, FKMassProperties *out, FKError *err) {
    clearError(err);
    if (!hasShape(shape, err) || !out) return FK_ERR_INVALID_ARGUMENT;
    FK_BEGIN
    GProp_GProps vprops;
    BRepGProp::VolumeProperties(shape->shape, vprops);
    GProp_GProps sprops;
    BRepGProp::SurfaceProperties(shape->shape, sprops);
    out->volume = vprops.Mass();
    out->surfaceArea = sprops.Mass();
    const GProp_GProps &primary = std::fabs(out->volume) > 1e-12 ? vprops : sprops;
    put3(out->centroid, primary.CentreOfMass().XYZ());
    gp_Mat I = primary.MatrixOfInertia();
    for (int r = 0; r < 3; ++r)
        for (int c = 0; c < 3; ++c) out->inertia[r * 3 + c] = I.Value(r + 1, c + 1);
    double i1, i2, i3;
    primary.PrincipalProperties().Moments(i1, i2, i3);
    double pm[3] = {i1, i2, i3};
    std::sort(pm, pm + 3);
    for (int i = 0; i < 3; ++i) out->principalMoments[i] = pm[i];
    return FK_OK;
    FK_END(FK_ERR_KERNEL_EXCEPTION)
}

int32_t fk_bounding_box(const FKShape *shape, int32_t optimal, double out[6], FKError *err) {
    clearError(err);
    if (!hasShape(shape, err) || !out) return FK_ERR_INVALID_ARGUMENT;
    FK_BEGIN
    Bnd_Box box;
    if (optimal)
        BRepBndLib::AddOptimal(shape->shape, box, Standard_False, Standard_False);
    else
        BRepBndLib::Add(shape->shape, box);
    if (box.IsVoid()) {
        setError(err, FK_ERR_EMPTY_RESULT, "shape has no extent");
        return FK_ERR_EMPTY_RESULT;
    }
    box.Get(out[0], out[1], out[2], out[3], out[4], out[5]);
    return FK_OK;
    FK_END(FK_ERR_KERNEL_EXCEPTION)
}

int32_t fk_check(const FKShape *shape, FKValidity *out, FKError *err) {
    clearError(err);
    if (!hasShape(shape, err) || !out) return FK_ERR_INVALID_ARGUMENT;
    FK_BEGIN
    out->isEmpty = shape->shape.IsNull() ? 1 : 0;
    if (out->isEmpty) {
        out->isValid = 0;
        out->isClosed = 0;
        out->freeEdges = 0;
        return FK_OK;
    }
    BRepCheck_Analyzer analyzer(shape->shape);
    out->isValid = analyzer.IsValid() ? 1 : 0;
    TopTools_IndexedDataMapOfShapeListOfShape edgeFaces;
    TopExp::MapShapesAndAncestors(shape->shape, TopAbs_EDGE, TopAbs_FACE, edgeFaces);
    int32_t freeEdges = 0;
    for (int i = 1; i <= edgeFaces.Extent(); ++i) {
        const TopoDS_Edge &e = TopoDS::Edge(edgeFaces.FindKey(i));
        if (BRep_Tool::Degenerated(e)) continue;
        if (edgeFaces(i).Extent() == 1 && !BRep_Tool::IsClosed(e, TopoDS::Face(edgeFaces(i).First())))
            ++freeEdges;
    }
    out->freeEdges = freeEdges;
    out->isClosed = freeEdges == 0 ? 1 : 0;
    return FK_OK;
    FK_END(FK_ERR_KERNEL_EXCEPTION)
}

int32_t fk_face_info(const FKShape *shape, int32_t faceIndex, FKFaceInfo *out, FKError *err) {
    clearError(err);
    if (!hasShape(shape, err) || !out) return FK_ERR_INVALID_ARGUMENT;
    FK_BEGIN
    TopTools_IndexedMapOfShape faces;
    TopExp::MapShapes(shape->shape, TopAbs_FACE, faces);
    if (faceIndex < 0 || faceIndex >= faces.Extent()) {
        setError(err, FK_ERR_OUT_OF_RANGE, "face index out of range");
        return FK_ERR_OUT_OF_RANGE;
    }
    TopoDS_Face face = TopoDS::Face(faces(faceIndex + 1));
    BRepAdaptor_Surface surf(face, Standard_True);
    out->surfaceType = surfaceType(surf.GetType());
    GProp_GProps props;
    BRepGProp::SurfaceProperties(face, props);
    out->area = props.Mass();
    put3(out->centroid, props.CentreOfMass().XYZ());
    double u0, u1, v0, v1;
    BRepTools::UVBounds(face, u0, u1, v0, v1);
    gp_Vec n(0, 0, 0);
    if (!faceNormal(surf, face, 0.5 * (u0 + u1), 0.5 * (v0 + v1), n)) {
        // Singular at the centre (e.g. sphere pole in some parameterisations): nudge.
        faceNormal(surf, face, u0 + 0.37 * (u1 - u0), v0 + 0.41 * (v1 - v0), n);
    }
    put3(out->normal, n.XYZ());
    TopTools_IndexedMapOfShape edges;
    TopExp::MapShapes(face, TopAbs_EDGE, edges);
    out->edgeCount = edges.Extent();
    return FK_OK;
    FK_END(FK_ERR_KERNEL_EXCEPTION)
}

int32_t fk_edge_info(const FKShape *shape, int32_t edgeIndex, FKEdgeInfo *out, FKError *err) {
    clearError(err);
    if (!hasShape(shape, err) || !out) return FK_ERR_INVALID_ARGUMENT;
    FK_BEGIN
    TopTools_IndexedMapOfShape edges;
    TopExp::MapShapes(shape->shape, TopAbs_EDGE, edges);
    if (edgeIndex < 0 || edgeIndex >= edges.Extent()) {
        setError(err, FK_ERR_OUT_OF_RANGE, "edge index out of range");
        return FK_ERR_OUT_OF_RANGE;
    }
    TopoDS_Edge edge = TopoDS::Edge(edges(edgeIndex + 1));
    std::memset(out, 0, sizeof(*out));
    out->isDegenerate = BRep_Tool::Degenerated(edge) ? 1 : 0;
    put3(out->start, BRep_Tool::Pnt(TopExp::FirstVertex(edge, Standard_True)).XYZ());
    put3(out->end, BRep_Tool::Pnt(TopExp::LastVertex(edge, Standard_True)).XYZ());
    if (!out->isDegenerate) {
        BRepAdaptor_Curve curve(edge);
        out->curveType = curveType(curve.GetType());
        out->length = GCPnts_AbscissaPoint::Length(curve);
        put3(out->midpoint, curve.Value(0.5 * (curve.FirstParameter() + curve.LastParameter())).XYZ());
    } else {
        out->curveType = FK_CURVE_OTHER;
        std::memcpy(out->midpoint, out->start, sizeof(out->midpoint));
    }
    TopTools_IndexedDataMapOfShapeListOfShape edgeFaces;
    TopExp::MapShapesAndAncestors(shape->shape, TopAbs_EDGE, TopAbs_FACE, edgeFaces);
    TopTools_IndexedMapOfShape unique;
    if (edgeFaces.Contains(edge))
        for (const TopoDS_Shape &f : edgeFaces.FindFromKey(edge)) unique.Add(f);
    out->adjacentFaces = unique.Extent();
    return FK_OK;
    FK_END(FK_ERR_KERNEL_EXCEPTION)
}

int32_t fk_edge_faces(const FKShape *shape, int32_t edgeIndex, int32_t *outFaces, int32_t maxOut, FKError *err) {
    clearError(err);
    if (!hasShape(shape, err) || (!outFaces && maxOut > 0)) return -1;
    FK_BEGIN
    TopTools_IndexedMapOfShape edges, faces;
    TopExp::MapShapes(shape->shape, TopAbs_EDGE, edges);
    TopExp::MapShapes(shape->shape, TopAbs_FACE, faces);
    if (edgeIndex < 0 || edgeIndex >= edges.Extent()) {
        setError(err, FK_ERR_OUT_OF_RANGE, "edge index out of range");
        return -1;
    }
    const TopoDS_Shape &edge = edges(edgeIndex + 1);
    std::vector<int32_t> found;
    for (int i = 1; i <= faces.Extent(); ++i) {
        for (TopExp_Explorer ex(faces(i), TopAbs_EDGE); ex.More(); ex.Next()) {
            if (ex.Current().IsSame(edge)) {
                found.push_back(i - 1);
                break;
            }
        }
    }
    for (int32_t i = 0; i < (int32_t)found.size() && i < maxOut; ++i) outFaces[i] = found[i];
    return static_cast<int32_t>(found.size());
    FK_END(-1)
}

int32_t fk_distance(const FKShape *a, const FKShape *b, double *outDistance, double outPointA[3], double outPointB[3], FKError *err) {
    clearError(err);
    if (!hasShape(a, err) || !hasShape(b, err) || !outDistance) return FK_ERR_INVALID_ARGUMENT;
    FK_BEGIN
    BRepExtrema_DistShapeShape dist(a->shape, b->shape);
    if (!dist.IsDone() || dist.NbSolution() < 1) {
        setError(err, FK_ERR_CONSTRUCTION_FAILED, "distance computation failed");
        return FK_ERR_CONSTRUCTION_FAILED;
    }
    *outDistance = dist.Value();
    if (outPointA) put3(outPointA, dist.PointOnShape1(1).XYZ());
    if (outPointB) put3(outPointB, dist.PointOnShape2(1).XYZ());
    return FK_OK;
    FK_END(FK_ERR_KERNEL_EXCEPTION)
}

// ---- tessellation ------------------------------------------------------------

FKMesh *fk_tessellate(const FKShape *shape, double linearDeflection, double angularDeflection, FKError *err) {
    clearError(err);
    if (!hasShape(shape, err)) return nullptr;
    FK_BEGIN
    const TopoDS_Shape &original = shape->shape;
    double lin = linearDeflection > 0 ? linearDeflection : autoDeflection(original);
    double ang = angularDeflection > 0 ? angularDeflection : 0.35;

    // Meshing stores triangulations on the faces' TShapes, which are shared by every copy
    // of a TopoDS_Shape. Mesh a deep copy so the caller's handle stays immutable.
    BRepBuilderAPI_Copy copier(original, Standard_True, Standard_False);
    TopoDS_Shape work = copier.Shape();
    BRepMesh_IncrementalMesh mesher(work, lin, Standard_False, ang, Standard_False);
    (void)mesher;

    auto mesh = std::make_unique<FKMesh>();
    TopTools_IndexedMapOfShape faces;
    TopExp::MapShapes(original, TopAbs_FACE, faces);
    for (int fi = 1; fi <= faces.Extent(); ++fi) {
        TopoDS_Face face = TopoDS::Face(copier.ModifiedShape(faces(fi)));
        // ModifiedShape returns the copied sub-shape with the original's orientation.
        face.Orientation(faces(fi).Orientation());
        TopLoc_Location loc;
        Handle(Poly_Triangulation) tri = BRep_Tool::Triangulation(face, loc);
        if (tri.IsNull()) continue;
        const gp_Trsf trsf = loc.Transformation();
        const bool reversed = face.Orientation() == TopAbs_REVERSED;
        const bool hasUV = tri->HasUVNodes();
        BRepAdaptor_Surface surf(face, Standard_False);
        const uint32_t base = static_cast<uint32_t>(mesh->positions.size() / 3);
        const int nNodes = tri->NbNodes();
        std::vector<gp_Vec> normals(nNodes, gp_Vec(0, 0, 0));
        std::vector<bool> haveNormal(nNodes, false);
        for (int i = 1; i <= nNodes; ++i) {
            gp_Pnt p = tri->Node(i).Transformed(trsf);
            mesh->positions.push_back(static_cast<float>(p.X()));
            mesh->positions.push_back(static_cast<float>(p.Y()));
            mesh->positions.push_back(static_cast<float>(p.Z()));
            if (hasUV) {
                gp_Pnt2d uv = tri->UVNode(i);
                gp_Vec n;
                if (faceNormal(surf, face, uv.X(), uv.Y(), n)) {
                    normals[i - 1] = n;
                    haveNormal[i - 1] = true;
                }
            }
        }
        const int nTris = tri->NbTriangles();
        std::vector<gp_Vec> accum(nNodes, gp_Vec(0, 0, 0));
        for (int t = 1; t <= nTris; ++t) {
            int n1, n2, n3;
            tri->Triangle(t).Get(n1, n2, n3);
            if (reversed) std::swap(n2, n3);
            mesh->indices.push_back(base + n1 - 1);
            mesh->indices.push_back(base + n2 - 1);
            mesh->indices.push_back(base + n3 - 1);
            mesh->triangleFaces.push_back(static_cast<uint32_t>(fi - 1));
            gp_Pnt p1 = tri->Node(n1).Transformed(trsf), p2 = tri->Node(n2).Transformed(trsf),
                   p3 = tri->Node(n3).Transformed(trsf);
            gp_Vec fn = gp_Vec(p1, p2).Crossed(gp_Vec(p1, p3)); // area-weighted
            accum[n1 - 1] += fn;
            accum[n2 - 1] += fn;
            accum[n3 - 1] += fn;
        }
        for (int i = 0; i < nNodes; ++i) {
            gp_Vec n = haveNormal[i] ? normals[i] : accum[i];
            if (n.Magnitude() > 1e-20) n.Normalize();
            mesh->normals.push_back(static_cast<float>(n.X()));
            mesh->normals.push_back(static_cast<float>(n.Y()));
            mesh->normals.push_back(static_cast<float>(n.Z()));
        }
    }

    TopTools_IndexedMapOfShape edges;
    TopExp::MapShapes(original, TopAbs_EDGE, edges);
    for (int ei = 1; ei <= edges.Extent(); ++ei) {
        const TopoDS_Edge &edge = TopoDS::Edge(edges(ei));
        if (BRep_Tool::Degenerated(edge)) continue;
        BRepAdaptor_Curve curve(edge);
        GCPnts_TangentialDeflection pts(curve, ang, lin);
        if (pts.NbPoints() < 2) continue;
        for (int i = 1; i <= pts.NbPoints(); ++i) {
            gp_Pnt p = pts.Value(i);
            mesh->edgePoints.push_back(static_cast<float>(p.X()));
            mesh->edgePoints.push_back(static_cast<float>(p.Y()));
            mesh->edgePoints.push_back(static_cast<float>(p.Z()));
        }
        mesh->edgeIds.push_back(static_cast<uint32_t>(ei - 1));
        mesh->edgeOffsets.push_back(static_cast<uint32_t>(mesh->edgePoints.size() / 3));
    }
    return mesh.release();
    FK_END(nullptr)
}

size_t fk_mesh_vertex_count(const FKMesh *m) { return m ? m->positions.size() / 3 : 0; }
size_t fk_mesh_triangle_count(const FKMesh *m) { return m ? m->indices.size() / 3 : 0; }
const float *fk_mesh_positions(const FKMesh *m) { return m ? m->positions.data() : nullptr; }
const float *fk_mesh_normals(const FKMesh *m) { return m ? m->normals.data() : nullptr; }
const uint32_t *fk_mesh_indices(const FKMesh *m) { return m ? m->indices.data() : nullptr; }
const uint32_t *fk_mesh_triangle_faces(const FKMesh *m) { return m ? m->triangleFaces.data() : nullptr; }
size_t fk_mesh_edge_count(const FKMesh *m) { return m ? m->edgeIds.size() : 0; }
const uint32_t *fk_mesh_edge_offsets(const FKMesh *m) { return m ? m->edgeOffsets.data() : nullptr; }
const uint32_t *fk_mesh_edge_ids(const FKMesh *m) { return m ? m->edgeIds.data() : nullptr; }
const float *fk_mesh_edge_points(const FKMesh *m) { return m ? m->edgePoints.data() : nullptr; }

// ---- serialization & exchange ------------------------------------------------

int32_t fk_write_brep(const FKShape *shape, uint8_t **outData, size_t *outSize, FKError *err) {
    clearError(err);
    if (!hasShape(shape, err) || !outData || !outSize) return FK_ERR_INVALID_ARGUMENT;
    FK_BEGIN
    // Geometry only: tessellation is cached separately (docs/adr/0004-file-format.md).
    auto write = [](const TopoDS_Shape &s) {
        std::ostringstream ss(std::ios::out | std::ios::binary);
        BinTools::Write(s, ss, Standard_False, Standard_False, BinTools_FormatVersion_CURRENT);
        return ss.str();
    };
    // Canonicalise: reading sets per-TShape status flags (e.g. "checked") that a fresh shape
    // lacks, so write(read(x)) != x for a newly built shape. One read/write pass reaches the
    // fixed point, making save(load(file)) byte-identical to the file.
    std::string bytes = write(shape->shape);
    {
        std::istringstream in(bytes, std::ios::in | std::ios::binary);
        TopoDS_Shape reread;
        BinTools::Read(reread, in);
        bytes = write(reread);
    }
    auto *buf = static_cast<uint8_t *>(std::malloc(bytes.size() ? bytes.size() : 1));
    if (!buf) {
        setError(err, FK_ERR_IO, "out of memory");
        return FK_ERR_IO;
    }
    std::memcpy(buf, bytes.data(), bytes.size());
    *outData = buf;
    *outSize = bytes.size();
    return FK_OK;
    FK_END(FK_ERR_KERNEL_EXCEPTION)
}

FKShape *fk_read_brep(const uint8_t *data, size_t size, FKError *err) {
    clearError(err);
    if (!data || size == 0) {
        setError(err, FK_ERR_INVALID_ARGUMENT, "empty BREP buffer");
        return nullptr;
    }
    FK_BEGIN
    std::istringstream ss(std::string(reinterpret_cast<const char *>(data), size), std::ios::in | std::ios::binary);
    TopoDS_Shape s;
    BinTools::Read(s, ss);
    if (s.IsNull()) {
        setError(err, FK_ERR_IO, "BREP data did not contain a shape");
        return nullptr;
    }
    return wrap(s);
    FK_END(nullptr)
}

int32_t fk_export_step(const FKShape *const *shapes, size_t count, const char *path, FKError *err) {
    clearError(err);
    if (!shapes || count == 0 || !path) {
        setError(err, FK_ERR_INVALID_ARGUMENT, "nothing to export");
        return FK_ERR_INVALID_ARGUMENT;
    }
    FK_BEGIN
    std::lock_guard<std::mutex> lock(dataExchangeMutex());
    STEPControl_Writer writer;
    Interface_Static::SetCVal("write.step.unit", "MM");
    for (size_t i = 0; i < count; ++i) {
        if (!shapes[i]) continue;
        if (writer.Transfer(shapes[i]->shape, STEPControl_AsIs) != IFSelect_RetDone) {
            setError(err, FK_ERR_IO, "STEP transfer failed");
            return FK_ERR_IO;
        }
    }
    if (writer.Write(path) != IFSelect_RetDone) {
        setError(err, FK_ERR_IO, "could not write STEP file");
        return FK_ERR_IO;
    }
    return FK_OK;
    FK_END(FK_ERR_KERNEL_EXCEPTION)
}

FKShape *fk_import_step(const char *path, FKError *err) {
    clearError(err);
    if (!path) {
        setError(err, FK_ERR_INVALID_ARGUMENT, "no path");
        return nullptr;
    }
    FK_BEGIN
    std::lock_guard<std::mutex> lock(dataExchangeMutex());
    STEPControl_Reader reader;
    if (reader.ReadFile(path) != IFSelect_RetDone) {
        setError(err, FK_ERR_IO, "could not read STEP file");
        return nullptr;
    }
    reader.TransferRoots();
    TopoDS_Shape s = reader.OneShape();
    if (s.IsNull()) {
        setError(err, FK_ERR_EMPTY_RESULT, "STEP file contained no shapes");
        return nullptr;
    }
    return wrap(s);
    FK_END(nullptr)
}

int32_t fk_export_stl(const FKShape *shape, const char *path, int32_t ascii, double linearDeflection, FKError *err) {
    clearError(err);
    if (!hasShape(shape, err) || !path) return FK_ERR_INVALID_ARGUMENT;
    FK_BEGIN
    BRepBuilderAPI_Copy copier(shape->shape, Standard_True, Standard_False);
    TopoDS_Shape work = copier.Shape();
    double lin = linearDeflection > 0 ? linearDeflection : autoDeflection(work);
    BRepMesh_IncrementalMesh mesher(work, lin, Standard_False, 0.35, Standard_False);
    (void)mesher;
    std::lock_guard<std::mutex> lock(dataExchangeMutex());
    StlAPI_Writer writer;
    writer.ASCIIMode() = ascii ? Standard_True : Standard_False;
    if (!writer.Write(work, path)) {
        setError(err, FK_ERR_IO, "could not write STL file");
        return FK_ERR_IO;
    }
    return FK_OK;
    FK_END(FK_ERR_KERNEL_EXCEPTION)
}

} // extern "C"
