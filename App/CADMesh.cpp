// STEP and IGES files for the 3D view: read with Open CASCADE Technology and turned into triangles and lines.

#include "CADMesh.h"

#include <BRepAdaptor_Curve.hxx>
#include <BRepBndLib.hxx>
#include <BRepMesh_IncrementalMesh.hxx>
#include <BRepTools.hxx>
#include <BRep_Tool.hxx>
#include <Bnd_Box.hxx>
#include <GCPnts_TangentialDeflection.hxx>
#include <IFSelect_ReturnStatus.hxx>
#include <IGESControl_Reader.hxx>
#include <Interface_Static.hxx>
#include <Message.hxx>
#include <Message_Messenger.hxx>
#include <Message_PrinterOStream.hxx>
#include <Poly_Triangle.hxx>
#include <Poly_Triangulation.hxx>
#include <STEPControl_Reader.hxx>
#include <Standard_Failure.hxx>
#include <Standard_OutOfMemory.hxx>
#include <TopAbs_Orientation.hxx>
#include <TopExp_Explorer.hxx>
#include <TopLoc_Location.hxx>
#include <TopoDS.hxx>
#include <TopoDS_Edge.hxx>
#include <TopoDS_Face.hxx>
#include <TopoDS_Shape.hxx>
#include <gp_Pnt.hxx>
#include <gp_Trsf.hxx>

#include <Message_ProgressIndicator.hxx>
#include <atomic>
#include <chrono>
#include <algorithm>
#include <cmath>
#include <cstdlib>
#include <mutex>
#include <new>
#include <vector>

struct CADCancel { std::atomic<bool> stopped{false}; };

extern "C" CADCancel *CADCancelCreate() { return new (std::nothrow) CADCancel; }
extern "C" void CADCancelRequest(CADCancel *token) { if (token) token->stopped.store(true); }
extern "C" void CADCancelFree(CADCancel *token) { delete token; }

namespace {
struct Cancelled {};
class ReadProgress : public Message_ProgressIndicator {
public:
    explicit ReadProgress(const CADCancel *token) : token_(token) {}
    Standard_Boolean UserBreak() override { return token_ && token_->stopped.load(); }
    void check() { if (UserBreak()) throw Cancelled(); }
private:
    const CADCancel *token_;
    void Show(const Message_ProgressScope&, Standard_Boolean) override {}
};

enum Status { Read = 0, Unreadable = 1, Empty = 2, TooBig = 3, NoMemory = 4 };

// Line segments from edges that aren't part of a surface; more than this isn't worth drawing on a phone.
const long maxSegments = 2000000;

// One file at a time: the readers share their settings.
std::timed_mutex &gate() {
    static std::timed_mutex shared;
    return shared;
}

// The readers print progress and warnings, which an app has nowhere to show.
void quiet() {
    static bool done = false;
    if (done) return;
    done = true;
    Message::DefaultMessenger()->RemovePrinters(STANDARD_TYPE(Message_PrinterOStream));
}

// The file's shapes. readable is false when the file can't be read at all; a file read with nothing in it
// gives a null shape.
TopoDS_Shape load(const char *path, int format, bool &readable, ReadProgress &progress) {
    if (format == 1) {
        IGESControl_Reader reader;
        // Only what the drawing shows, not hidden construction geometry.
        Interface_Static::SetIVal("read.iges.onlyvisible", 1);
        reader.SetReadVisible(Standard_True);
        readable = reader.ReadFile(path) == IFSelect_RetDone;
        if (!readable) return TopoDS_Shape();
        progress.check();
        reader.TransferRoots(progress.Start());
        progress.check();
        return reader.OneShape();
    }
    STEPControl_Reader reader;
    readable = reader.ReadFile(path) == IFSelect_RetDone;
    if (!readable) return TopoDS_Shape();
    progress.check();
    reader.TransferRoots(progress.Start());
    progress.check();
    return reader.OneShape();
}

// The size of the model: the length of its box's diagonal.
double diagonal(const TopoDS_Shape &shape) {
    Bnd_Box box;
    BRepBndLib::Add(shape, box, Standard_False);
    if (box.IsVoid()) return 0;
    const double size = std::sqrt(box.SquareExtent());
    // Shapes that run on forever (construction planes and lines) would make the box useless.
    return std::isfinite(size) && size < 1e7 ? size : 1000;
}

long triangleCount(const TopoDS_Shape &shape, ReadProgress &progress) {
    long count = 0;
    for (TopExp_Explorer explorer(shape, TopAbs_FACE); explorer.More(); explorer.Next()) {
        progress.check();
        TopLoc_Location location;
        const Handle(Poly_Triangulation) &mesh = BRep_Tool::Triangulation(TopoDS::Face(explorer.Current()), location);
        if (!mesh.IsNull()) count += mesh->NbTriangles();
    }
    return count;
}

// Corners of every triangle, placed where each face sits in the model.
long fillTriangles(const TopoDS_Shape &shape, float *out, long capacity, ReadProgress &progress) {
    long written = 0;
    for (TopExp_Explorer explorer(shape, TopAbs_FACE); explorer.More(); explorer.Next()) {
        progress.check();
        const TopoDS_Face &face = TopoDS::Face(explorer.Current());
        TopLoc_Location location;
        const Handle(Poly_Triangulation) &mesh = BRep_Tool::Triangulation(face, location);
        if (mesh.IsNull()) continue;
        const gp_Trsf transform = location.Transformation();
        // A face turned the other way lists its corners the other way round, so it faces out.
        const bool reversed = face.Orientation() == TopAbs_REVERSED;
        const Standard_Integer nodes = mesh->NbNodes();
        for (Standard_Integer i = 1; i <= mesh->NbTriangles(); ++i) {
            if ((i & 1023) == 0) progress.check();
            Standard_Integer corners[3];
            mesh->Triangle(i).Get(corners[0], corners[1], corners[2]);
            if (reversed) std::swap(corners[1], corners[2]);
            if (written + 9 > capacity) return written;
            bool valid = true;
            for (Standard_Integer corner : corners) valid = valid && corner >= 1 && corner <= nodes;
            if (!valid) continue;
            for (Standard_Integer corner : corners) {
                const gp_Pnt point = mesh->Node(corner).Transformed(transform);
                out[written++] = static_cast<float>(point.X());
                out[written++] = static_cast<float>(point.Y());
                out[written++] = static_cast<float>(point.Z());
            }
        }
    }
    return written;
}

// Edges that aren't part of a surface (wireframes and loose curves), as short straight segments.
void freeEdges(const TopoDS_Shape &shape, double deflection, std::vector<float> &out, ReadProgress &progress) {
    for (TopExp_Explorer explorer(shape, TopAbs_EDGE, TopAbs_FACE); explorer.More(); explorer.Next()) {
        progress.check();
        const TopoDS_Edge &edge = TopoDS::Edge(explorer.Current());
        if (BRep_Tool::Degenerated(edge)) continue;
        try {
            BRepAdaptor_Curve curve(edge);
            GCPnts_TangentialDeflection points(curve, 0.2, deflection);
            for (Standard_Integer i = 1; i < points.NbPoints(); ++i) {
                if ((i & 1023) == 0) progress.check();
                if (out.size() / 6 >= maxSegments) return;
                const gp_Pnt a = points.Value(i);
                const gp_Pnt b = points.Value(i + 1);
                out.insert(out.end(), {static_cast<float>(a.X()), static_cast<float>(a.Y()), static_cast<float>(a.Z()),
                                       static_cast<float>(b.X()), static_cast<float>(b.Y()), static_cast<float>(b.Z())});
            }
        } catch (const Standard_Failure &) {
            // An edge without a usable curve is left out.
        }
        if (static_cast<long>(out.size() / 6) >= maxSegments) return;
    }
}

int read(const char *path, int format, long maxTriangles, CADMesh *result, ReadProgress &progress) {
    progress.check();
    quiet();
    bool readable = false;
    TopoDS_Shape shape = load(path, format, readable, progress);
    progress.check();
    if (!readable) return Unreadable;
    if (shape.IsNull()) return Empty;
    const double size = diagonal(shape);
    if (size <= 0) return Empty;

    // Curved faces become triangles no further than 0.1% of the model's size from the real surface.
    double deflection = size * 0.001;
    auto triangulate = [&](double angle) {
        progress.check();
        IMeshTools_Parameters parameters;
        parameters.Deflection = deflection;
        parameters.Angle = angle;
        parameters.InParallel = Standard_True;
        BRepMesh_IncrementalMesh mesher(shape, parameters, progress.Start());
        progress.check();
    };
    triangulate(0.35);
    long count = triangleCount(shape, progress);
    if (count > maxTriangles) {
        // Too detailed for a phone: once more, coarser.
        BRepTools::Clean(shape);
        deflection *= 6;
        triangulate(0.9);
        count = triangleCount(shape, progress);
        if (count > maxTriangles) return TooBig;
    }

    if (count > 0) {
        const long capacity = count * 9;
        result->triangles = static_cast<float *>(std::malloc(static_cast<size_t>(capacity) * sizeof(float)));
        if (!result->triangles) return NoMemory;
        result->triangleFloats = fillTriangles(shape, result->triangles, capacity, progress);
    }

    std::vector<float> lines;
    freeEdges(shape, deflection, lines, progress);
    if (!lines.empty()) {
        result->lines = static_cast<float *>(std::malloc(lines.size() * sizeof(float)));
        if (!result->lines) return NoMemory;
        std::copy(lines.begin(), lines.end(), result->lines);
        result->lineFloats = static_cast<long>(lines.size());
    }
    return result->triangleFloats > 0 || result->lineFloats > 0 ? Read : Empty;
}

}  // namespace

extern "C" CADMesh *CADMeshRead(const char *path, int format, long maxTriangles, const CADCancel *token) {
    CADMesh *result = static_cast<CADMesh *>(std::calloc(1, sizeof(CADMesh)));
    if (!result) return nullptr;
    int status = Unreadable;
    try {
        Handle(ReadProgress) progress = new ReadProgress(token);
        std::unique_lock<std::timed_mutex> lock(gate(), std::defer_lock);
        while (!lock.try_lock_for(std::chrono::milliseconds(50))) progress->check();
        status = read(path, format, maxTriangles, result, *progress);
        progress->check();
    } catch (const Cancelled &) {
        status = 5;
    } catch (const std::bad_alloc &) {
        status = NoMemory;
    } catch (const Standard_OutOfMemory &) {
        status = NoMemory;
    } catch (const Standard_Failure &) {
        status = Unreadable;
    } catch (...) {
        status = Unreadable;
    }
    if (status != Read) {
        std::free(result->triangles);
        std::free(result->lines);
        *result = CADMesh();
    }
    result->status = status;
    return result;
}

extern "C" void CADMeshFree(CADMesh *mesh) {
    if (!mesh) return;
    std::free(mesh->triangles);
    std::free(mesh->lines);
    std::free(mesh);
}
