// A small C interface to Clipper2 for Swift (see Geometry/Clipper.swift).
// Paths are flat arrays of integer coordinates (x0, y0, x1, y1, …) with a
// point count per path. Results are allocated here and released with
// cs_free. Clipper2 exceptions never cross this boundary: a failed call
// returns ok = 0.
#ifndef CLIPPER_SHIM_H
#define CLIPPER_SHIM_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    int64_t *coords;     // 2 × total points
    int32_t *counts;     // points per path
    int32_t pathCount;
    int32_t ok;
} CSPaths;

// op: 0 intersection, 1 union, 2 difference, 3 xor.
// fillRule: 0 even-odd, 1 non-zero, 2 positive, 3 negative.
// Open subject paths (lines) are clipped as lines and returned after the
// closed results, their count in *openCount.
CSPaths cs_boolean(int op, int fillRule,
                   const int64_t *subject, const int32_t *subjectCounts, int32_t subjectPaths,
                   const int64_t *openSubject, const int32_t *openCounts, int32_t openPaths,
                   const int64_t *clip, const int32_t *clipCounts, int32_t clipPaths,
                   int32_t *openCount);

// joinType: 0 square, 1 bevel, 2 round, 3 miter.
// endType: 0 polygon, 1 joined, 2 butt, 3 square, 4 round.
CSPaths cs_inflate(const int64_t *paths, const int32_t *counts, int32_t pathCount,
                   double delta, int joinType, int endType, double miterLimit, double arcTolerance);

void cs_free(CSPaths paths);

#ifdef __cplusplus
}
#endif

#endif
