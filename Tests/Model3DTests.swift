import XCTest
import SceneKit
@testable import Newexplorer

// The 3D view's files: STL (binary and text), 3MF with parts, moves and colors, OBJ through Model I/O, and DXF in 3D.
final class Model3DTests: XCTestCase {
    private let corners: [Float] = [0, 0, 0, 10, 0, 0, 0, 10, 0,
                                    0, 0, 5, 10, 0, 5, 0, 10, 5]

    private func bytes<T>(_ value: T) -> [UInt8] { withUnsafeBytes(of: value) { Array($0) } }

    // 80-byte header, the triangle count, then each triangle: normal, three corners, 2 spare bytes.
    private func binarySTL(header: String = "") -> Data {
        var data = Data(Array(header.utf8.prefix(80)) + [UInt8](repeating: 0, count: 80 - min(header.utf8.count, 80)))
        data.append(contentsOf: bytes(UInt32(2).littleEndian))
        for t in 0..<2 {
            for value in [Float(0), 0, 1] + corners[(t * 9)..<(t * 9 + 9)] {
                data.append(contentsOf: bytes(value.bitPattern.littleEndian))
            }
            data.append(contentsOf: [0, 0])
        }
        return data
    }

    func testSTLBinaryAndText() throws {
        XCTAssertEqual(try STLReader.read(binarySTL()), corners)
        // Some programs start binary files with "solid" too; the exact size shows they're binary.
        XCTAssertEqual(try STLReader.read(binarySTL(header: "solid exported part")), corners)
        let text = """
        solid part
          facet normal 0 0 1
            outer loop
              vertex 0 0 0
              vertex 10 0 0
              vertex 0 10 0
            endloop
          endfacet
          facet normal 0 0 1
            outer loop
              vertex 0 0 5
              vertex 1.0e1 0 5
              vertex 0 10 5
            endloop
          endfacet
        endsolid part
        """
        XCTAssertEqual(try STLReader.read(Data(text.replacingOccurrences(of: "\n", with: "\r\n").utf8)), corners)
        XCTAssertThrowsError(try STLReader.read(Data("solid empty\nendsolid empty\n".utf8)))

        let base = try Files.workspace()
        defer { try? Files.fm.removeItem(at: base) }
        let url = base.appendingPathComponent("Part.STL")
        try binarySTL().write(to: url)
        XCTAssertTrue(Model3DFile.handles("Part.STL"))
        XCTAssertTrue(Model3DFile.handles("box.3mf"))
        XCTAssertFalse(Model3DFile.handles("bracket.step"))
        guard case let .mesh(model) = try Model3DFile.load(url) else { return XCTFail("An STL file opens as a mesh.") }
        XCTAssertEqual(model.triangleCount, 2)
        XCTAssertTrue(model.zUp)
        XCTAssertEqual(model.extent.high.z, 5)
    }

    func testThreeMFPartsMovesAndColors() throws {
        let base = try Files.workspace()
        defer { try? Files.fm.removeItem(at: base) }
        let objects = base.appendingPathComponent("3D/Objects")
        try Files.fm.createDirectory(at: objects, withIntermediateDirectories: true)
        try Files.fm.createDirectory(at: base.appendingPathComponent("_rels"), withIntermediateDirectories: true)
        try Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
         <Relationship Target="/3D/3dmodel.model" Id="rel0" Type="http://schemas.microsoft.com/3dmanufacturing/2013/01/3dmodel"/>
        </Relationships>
        """.utf8).write(to: base.appendingPathComponent("_rels/.rels"))
        // The main model: a colored object, and an object made of a part from another file, as slicers write them.
        try Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <model unit="millimeter" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02"
               xmlns:p="http://schemas.microsoft.com/3dmanufacturing/production/2015/06"
               xmlns:m="http://schemas.microsoft.com/3dmanufacturing/material/2015/02">
         <resources>
          <m:colorgroup id="5"><m:color color="#FF0000"/><m:color color="#00FF00FF"/></m:colorgroup>
          <object id="1" type="model" pid="5" pindex="0">
           <mesh>
            <vertices><vertex x="0" y="0" z="0"/><vertex x="1" y="0" z="0"/><vertex x="0" y="1" z="0"/></vertices>
            <triangles><triangle v1="0" v2="1" v3="2"/><triangle v1="0" v2="2" v3="1" p1="1"/></triangles>
           </mesh>
          </object>
          <object id="2" type="model">
           <components>
            <component p:path="/3D/Objects/part.model" objectid="7" transform="1 0 0 0 1 0 0 0 1 100 0 0"/>
           </components>
          </object>
         </resources>
         <build>
          <item objectid="1" transform="2 0 0 0 2 0 0 0 2 0 0 10"/>
          <item objectid="2" transform="1 0 0 0 1 0 0 0 1 0 50 0"/>
         </build>
        </model>
        """.utf8).write(to: base.appendingPathComponent("3D/3dmodel.model"))
        try Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <model unit="millimeter" xmlns="http://schemas.microsoft.com/3dmanufacturing/core/2015/02">
         <resources>
          <basematerials id="3"><base name="Blue" displaycolor="#0000FF"/></basematerials>
          <object id="7" type="model" pid="3" pindex="0">
           <mesh>
            <vertices><vertex x="0" y="0" z="0"/><vertex x="2" y="0" z="0"/><vertex x="0" y="3" z="0"/></vertices>
            <triangles><triangle v1="0" v2="1" v3="2"/></triangles>
           </mesh>
          </object>
         </resources>
        </model>
        """.utf8).write(to: objects.appendingPathComponent("part.model"))
        let zip = try Files.zip([base.appendingPathComponent("3D"), base.appendingPathComponent("_rels")], named: "Box", in: base)
        let url = base.appendingPathComponent("Box.3mf")
        try Files.fm.moveItem(at: zip, to: url)

        var byInk: [DXFInk?: [Float]] = [:]
        for surface in try ThreeMFReader.read(url) { byInk[surface.ink] = surface.positions }
        XCTAssertEqual(byInk.count, 3)
        // Object 1: made twice as big and raised 10; its second triangle has its own color.
        XCTAssertEqual(byInk[DXFInk.rgb(255, 0, 0)], [0, 0, 10, 2, 0, 10, 0, 2, 10])
        XCTAssertEqual(byInk[DXFInk.rgb(0, 255, 0)], [0, 0, 10, 0, 2, 10, 2, 0, 10])
        // The part from the other file: moved 100 along X by its component, then 50 along Y by the build item.
        XCTAssertEqual(byInk[DXFInk.rgb(0, 0, 255)], [100, 50, 0, 102, 50, 0, 100, 53, 0])
        guard case let .mesh(model) = try Model3DFile.load(url) else { return XCTFail("A 3MF file opens as a mesh.") }
        XCTAssertEqual(model.triangleCount, 3)
    }

    func testOBJOpensThroughModelIO() throws {
        let base = try Files.workspace()
        defer { try? Files.fm.removeItem(at: base) }
        let url = base.appendingPathComponent("triangle.obj")
        try Data("v 0 0 0\nv 1 0 0\nv 0 1 0\nf 1 2 3\n".utf8).write(to: url)
        guard case let .scene(scene) = try Model3DFile.load(url) else { return XCTFail("An OBJ file opens through Model I/O.") }
        var shapes = 0
        scene.rootNode.enumerateHierarchy { node, _ in if node.geometry != nil { shapes += 1 } }
        XCTAssertGreaterThan(shapes, 0)
    }

    func testDXFIn3D() throws {
        let pairs: [(Int, String)] = [
            (0, "SECTION"), (2, "ENTITIES"),
            (0, "3DFACE"), (8, "0"), (10, "0"), (20, "0"), (30, "0"), (11, "10"), (21, "0"), (31, "0"),
            (12, "10"), (22, "10"), (32, "5"), (13, "0"), (23, "10"), (33, "5"),
            (0, "LINE"), (8, "0"), (10, "0"), (20, "0"), (30, "0"), (11, "0"), (21, "0"), (31, "20"),
            (0, "POINT"), (8, "0"), (10, "5"), (20, "5"), (30, "5"),
            (0, "ENDSEC"), (0, "EOF")
        ]
        var file = ""
        for (code, value) in pairs { file += "\(code)\n\(value)\n" }
        let drawing = DXFDrawing(DXFDocument(try DXFReader.tags(from: Data(file.utf8))))
        XCTAssertEqual(drawing.model.faces.count, 1)

        let model = Model3D(dxf: drawing.model)
        // The 3D face is two triangles; its four edges and the line are lines; the point stays a point.
        XCTAssertEqual(model.triangleCount, 2)
        XCTAssertEqual(model.lines.reduce(0) { $0 + $1.positions.count }, 5 * 2 * 3)
        XCTAssertEqual(model.points.first?.positions, [0, 0, -5])
        // Everything is placed around the drawing's center.
        XCTAssertEqual(model.offset, DXFVec(5, 5, 10))
        XCTAssertEqual(model.extent.low, DXFVec(-5, -5, -10))
        XCTAssertEqual(model.extent.high, DXFVec(5, 5, 10))
    }
}
