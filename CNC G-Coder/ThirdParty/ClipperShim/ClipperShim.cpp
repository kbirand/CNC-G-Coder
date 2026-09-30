#include "ClipperShim.h"
#include "clipper2/clipper.h"
#include <cstdlib>

using namespace Clipper2Lib;

static Paths64 unpack(const int64_t *coords, const int32_t *counts, int32_t n) {
    Paths64 out;
    if (!coords || !counts) return out;
    out.reserve(n);
    size_t k = 0;
    for (int32_t i = 0; i < n; ++i) {
        Path64 p;
        p.reserve(counts[i]);
        for (int32_t j = 0; j < counts[i]; ++j, k += 2) p.emplace_back(coords[k], coords[k + 1]);
        out.push_back(std::move(p));
    }
    return out;
}

static CSPaths pack(const Paths64 &a, const Paths64 *b = nullptr) {
    CSPaths r{nullptr, nullptr, 0, 1};
    size_t paths = a.size() + (b ? b->size() : 0), points = 0;
    for (auto &p : a) points += p.size();
    if (b) for (auto &p : *b) points += p.size();
    r.coords = (int64_t *)std::malloc(sizeof(int64_t) * (2 * points + 1));
    r.counts = (int32_t *)std::malloc(sizeof(int32_t) * (paths + 1));
    if (!r.coords || !r.counts) { std::free(r.coords); std::free(r.counts); return CSPaths{nullptr, nullptr, 0, 0}; }
    size_t k = 0, i = 0;
    auto put = [&](const Paths64 &set) {
        for (auto &p : set) {
            r.counts[i++] = (int32_t)p.size();
            for (auto &pt : p) { r.coords[k++] = pt.x; r.coords[k++] = pt.y; }
        }
    };
    put(a);
    if (b) put(*b);
    r.pathCount = (int32_t)paths;
    return r;
}

extern "C" CSPaths cs_boolean(int op, int fillRule,
                              const int64_t *subject, const int32_t *subjectCounts, int32_t subjectPaths,
                              const int64_t *openSubject, const int32_t *openCounts, int32_t openPaths,
                              const int64_t *clip, const int32_t *clipCounts, int32_t clipPaths,
                              int32_t *openCount) {
    try {
        Clipper64 c;
        c.PreserveCollinear(false);
        if (subjectPaths > 0) c.AddSubject(unpack(subject, subjectCounts, subjectPaths));
        if (openPaths > 0) c.AddOpenSubject(unpack(openSubject, openCounts, openPaths));
        if (clipPaths > 0) c.AddClip(unpack(clip, clipCounts, clipPaths));
        Paths64 closed, open;
        if (!c.Execute((ClipType)(op + 1), (FillRule)fillRule, closed, open)) return CSPaths{nullptr, nullptr, 0, 0};
        if (openCount) *openCount = (int32_t)open.size();
        return pack(closed, &open);
    } catch (...) {
        return CSPaths{nullptr, nullptr, 0, 0};
    }
}

extern "C" CSPaths cs_inflate(const int64_t *paths, const int32_t *counts, int32_t pathCount,
                              double delta, int joinType, int endType, double miterLimit, double arcTolerance) {
    try {
        Paths64 in = unpack(paths, counts, pathCount);
        ClipperOffset o(miterLimit, arcTolerance);
        o.AddPaths(in, (JoinType)joinType, (EndType)endType);
        Paths64 out;
        o.Execute(delta, out);
        return pack(out);
    } catch (...) {
        return CSPaths{nullptr, nullptr, 0, 0};
    }
}

extern "C" void cs_free(CSPaths paths) {
    std::free(paths.coords);
    std::free(paths.counts);
}
