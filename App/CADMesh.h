// STEP and IGES files for the 3D view, read with Open CASCADE Technology (CADMesh.cpp).
// A plain C interface, so Swift can call it through the bridging header.

#ifndef CADMESH_H
#define CADMESH_H

#ifdef __cplusplus
extern "C" {
#endif

// What a file holds, as triangles and lines: x, y and z of each corner or end, in millimetres.
typedef struct CADMesh {
    // 0: read; 1: the file can't be read; 2: it has no shapes; 3: too many triangles; 4: not enough memory; 5: cancelled.
    int status;
    // 9 floats per triangle.
    float *triangles;
    long triangleFloats;
    // 6 floats per line segment: edges that aren't part of a surface, such as IGES wireframes.
    float *lines;
    long lineFloats;
} CADMesh;

// format: 0 for STEP, 1 for IGES. Returns NULL only when there's no memory at all; free the result with CADMeshFree.
typedef struct CADCancel CADCancel;
CADCancel *CADCancelCreate(void);
void CADCancelRequest(CADCancel *token);
void CADCancelFree(CADCancel *token);
CADMesh *CADMeshRead(const char *path, int format, long maxTriangles, const CADCancel *token);
void CADMeshFree(CADMesh *mesh);

#ifdef __cplusplus
}
#endif

#endif
