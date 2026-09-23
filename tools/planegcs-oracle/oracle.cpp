// planegcs oracle for Forge's sketch solver (docs/adr/0003).
//
// Reads a sketch in a line-based format on stdin, solves it with FreeCAD's planegcs, runs its
// diagnosis, and prints the result on stdout. Test-only; built by build.sh as a separate
// executable (planegcs is LGPL-2.1+ and is never linked into Forge, docs/adr/0005).
//
// Input (one item per line, '#' comments):
//   p <index> <value>              parameter (all parameters are unknowns unless fixed)
//   fixed <index>                  parameter held constant (fixed geometry, dimension values)
//   point <id> <x> <y>             x/y are parameter indices
//   line <id> <point> <point>
//   circle <id> <centre point> <radius>
//   arc <id> <centre> <start> <end> <radius> <start angle> <end angle>   (+ planegcs ArcRules)
//   c <tag> <kind> <args…>         constraint; tag > 0 identifies it in the output
//     coincident P P | horizontal L | vertical L | hpoints P P | vpoints P P
//     parallel L L | perpendicular L L | angle L L v | ppdistance P P v | pldistance P L v
//     length L v | radius C v | diameter C v | equal L L | equalradius C C
//     online P L | oncircle P C | tangent L C | concentric C C | symmetric P P L | midpoint P L
//     difference i j v   (parameter j − parameter i = v; horizontal/vertical distances)
//   (C is a circle or an arc; v is a parameter index holding the value, normally fixed)
// Output:
//   status <int>  (0 success, 1 converged, 2 failed, 3 invalid)
//   dof <int>
//   conflicting <tags…>
//   redundant <tags…>
//   param <index> <value>          one per parameter, after solving

#include <cstdio>
#include <iostream>
#include <map>
#include <set>
#include <sstream>
#include <string>
#include <vector>

#include "GCS.h"

namespace {

struct Problem {
    std::vector<double> values;  // sized once parsing is done; geometry points into it
    std::set<int> fixed;
    std::map<std::string, GCS::Point> points;
    std::map<std::string, GCS::Line> lines;
    std::map<std::string, GCS::Circle> circles;
    std::map<std::string, GCS::Arc> arcs;
};

[[noreturn]] void fail(const std::string& why) {
    std::printf("error %s\n", why.c_str());
    std::exit(2);
}

}  // namespace

int main() {
    std::vector<std::vector<std::string>> items;
    std::string raw;
    int maxParam = -1;
    std::map<int, double> initial;
    while (std::getline(std::cin, raw)) {
        auto hash = raw.find('#');
        if (hash != std::string::npos) raw.erase(hash);
        std::istringstream in(raw);
        std::vector<std::string> w;
        for (std::string t; in >> t;) w.push_back(t);
        if (w.empty()) continue;
        if (w[0] == "p") {
            if (w.size() != 3) fail("bad p line");
            int i = std::stoi(w[1]);
            initial[i] = std::stod(w[2]);
            maxParam = std::max(maxParam, i);
        } else {
            items.push_back(w);
        }
    }
    Problem P;
    P.values.assign(maxParam + 1, 0.0);
    for (auto& [i, v] : initial) P.values[i] = v;
    auto param = [&](const std::string& s) -> double* {
        int i = std::stoi(s);
        if (i < 0 || i > maxParam) fail("parameter out of range: " + s);
        return &P.values[i];
    };
    auto pt = [&](const std::string& id) -> GCS::Point& {
        auto it = P.points.find(id);
        if (it == P.points.end()) fail("unknown point " + id);
        return it->second;
    };
    auto ln = [&](const std::string& id) -> GCS::Line& {
        auto it = P.lines.find(id);
        if (it == P.lines.end()) fail("unknown line " + id);
        return it->second;
    };

    GCS::System sys;
    for (auto& w : items) {
        const std::string& k = w[0];
        if (k == "fixed") {
            P.fixed.insert(std::stoi(w[1]));
        } else if (k == "point") {
            P.points.emplace(w[1], GCS::Point(param(w[2]), param(w[3])));
        } else if (k == "line") {
            GCS::Line l;
            l.p1 = pt(w[2]);
            l.p2 = pt(w[3]);
            P.lines.emplace(w[1], l);
        } else if (k == "circle") {
            GCS::Circle c;
            c.center = pt(w[2]);
            c.rad = param(w[3]);
            P.circles.emplace(w[1], c);
        } else if (k == "arc") {
            GCS::Arc a;
            a.center = pt(w[2]);
            a.start = pt(w[3]);
            a.end = pt(w[4]);
            a.rad = param(w[5]);
            a.startAngle = param(w[6]);
            a.endAngle = param(w[7]);
            auto& ref = P.arcs.emplace(w[1], a).first->second;
            sys.addConstraintArcRules(ref, 0);
        } else if (k == "c") {
            int tag = std::stoi(w[1]);
            const std::string& kind = w[2];
            auto arg = [&](size_t i) -> const std::string& {
                if (w.size() <= 3 + i) fail("missing argument for " + kind);
                return w[3 + i];
            };
            bool isArc0 = w.size() > 3 && P.arcs.count(arg(0)), isArc1 = w.size() > 4 && P.arcs.count(arg(1));
            auto circ = [&](const std::string& id) -> GCS::Circle& {
                auto it = P.circles.find(id);
                if (it == P.circles.end()) fail("unknown circle " + id);
                return it->second;
            };
            auto arc = [&](const std::string& id) -> GCS::Arc& { return P.arcs.at(id); };
            if (kind == "coincident") sys.addConstraintP2PCoincident(pt(arg(0)), pt(arg(1)), tag);
            else if (kind == "horizontal") sys.addConstraintHorizontal(ln(arg(0)), tag);
            else if (kind == "vertical") sys.addConstraintVertical(ln(arg(0)), tag);
            else if (kind == "hpoints") sys.addConstraintHorizontal(pt(arg(0)), pt(arg(1)), tag);
            else if (kind == "vpoints") sys.addConstraintVertical(pt(arg(0)), pt(arg(1)), tag);
            else if (kind == "parallel") sys.addConstraintParallel(ln(arg(0)), ln(arg(1)), tag);
            else if (kind == "perpendicular") sys.addConstraintPerpendicular(ln(arg(0)), ln(arg(1)), tag);
            else if (kind == "angle") sys.addConstraintL2LAngle(ln(arg(0)), ln(arg(1)), param(arg(2)), tag);
            else if (kind == "ppdistance") sys.addConstraintP2PDistance(pt(arg(0)), pt(arg(1)), param(arg(2)), tag);
            else if (kind == "pldistance") sys.addConstraintP2LDistance(pt(arg(0)), ln(arg(1)), param(arg(2)), tag);
            else if (kind == "length") {
                auto& l = ln(arg(0));
                sys.addConstraintP2PDistance(l.p1, l.p2, param(arg(1)), tag);
            } else if (kind == "radius") {
                if (isArc0) sys.addConstraintArcRadius(arc(arg(0)), param(arg(1)), tag);
                else sys.addConstraintCircleRadius(circ(arg(0)), param(arg(1)), tag);
            } else if (kind == "diameter") {
                if (isArc0) sys.addConstraintArcDiameter(arc(arg(0)), param(arg(1)), tag);
                else sys.addConstraintCircleDiameter(circ(arg(0)), param(arg(1)), tag);
            } else if (kind == "equal") sys.addConstraintEqualLength(ln(arg(0)), ln(arg(1)), tag);
            else if (kind == "equalradius") {
                if (isArc0 && isArc1) sys.addConstraintEqualRadius(arc(arg(0)), arc(arg(1)), tag);
                else if (isArc1) sys.addConstraintEqualRadius(circ(arg(0)), arc(arg(1)), tag);
                else if (isArc0) sys.addConstraintEqualRadius(circ(arg(1)), arc(arg(0)), tag);
                else sys.addConstraintEqualRadius(circ(arg(0)), circ(arg(1)), tag);
            } else if (kind == "online") sys.addConstraintPointOnLine(pt(arg(0)), ln(arg(1)), tag);
            else if (kind == "difference") sys.addConstraintDifference(param(arg(0)), param(arg(1)), param(arg(2)), tag);
            else if (kind == "symmetric") sys.addConstraintP2PSymmetric(pt(arg(0)), pt(arg(1)), ln(arg(2)), tag);
            else if (kind == "midpoint") {
                auto& l = ln(arg(1));
                sys.addConstraintP2PSymmetric(l.p1, l.p2, pt(arg(0)), tag);
            }
            else if (kind == "oncircle") {
                if (P.arcs.count(arg(1))) sys.addConstraintPointOnCircle(pt(arg(0)), arc(arg(1)), tag);
                else sys.addConstraintPointOnCircle(pt(arg(0)), circ(arg(1)), tag);
            } else if (kind == "tangent") {
                if (P.arcs.count(arg(1))) sys.addConstraintTangent(ln(arg(0)), arc(arg(1)), tag);
                else sys.addConstraintTangent(ln(arg(0)), circ(arg(1)), tag);
            } else if (kind == "concentric") {
                GCS::Point& a = isArc0 ? arc(arg(0)).center : circ(arg(0)).center;
                GCS::Point& b = isArc1 ? arc(arg(1)).center : circ(arg(1)).center;
                sys.addConstraintP2PCoincident(a, b, tag);
            } else fail("unknown constraint kind " + kind);
        } else {
            fail("unknown item " + k);
        }
    }

    GCS::VEC_pD unknowns;
    for (int i = 0; i <= maxParam; ++i)
        if (!P.fixed.count(i)) unknowns.push_back(&P.values[i]);
    sys.declareUnknowns(unknowns);
    // Same order as FreeCAD's Sketch: diagnose (which also sets up the reduced system without
    // redundant rows) before solving.
    sys.initSolution();
    sys.diagnose();
    int status = sys.solve(true, GCS::DogLeg);
    if (status == GCS::Success || status == GCS::Converged) sys.applySolution();
    GCS::VEC_I conflicting, redundant;
    sys.getConflicting(conflicting);
    sys.getRedundant(redundant);
    std::printf("status %d\ndof %d\nconflicting", status, sys.dofsNumber());
    for (int t : conflicting) std::printf(" %d", t);
    std::printf("\nredundant");
    for (int t : redundant) std::printf(" %d", t);
    std::printf("\n");
    for (int i = 0; i <= maxParam; ++i) std::printf("param %d %.17g\n", i, P.values[i]);
    return 0;
}
