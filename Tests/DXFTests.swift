import XCTest
@testable import Newexplorer

// DXF drawings: entities, blocks, layers, line types, curves, hatches, text, pictures, layouts and binary files.
final class DXFTests: XCTestCase {
    private typealias Pairs = [(Int, String)]

    private func section(_ name: String, _ body: Pairs) -> Pairs {
        var pairs: Pairs = [(0, "SECTION"), (2, name)]
        pairs += body
        pairs.append((0, "ENDSEC"))
        return pairs
    }
    private func text(_ pairs: Pairs) -> Data {
        var file = ""
        for (code, value) in pairs + [(0, "EOF")] { file += "\(code)\n\(value)\n" }
        return Data(file.utf8)
    }
    // The same pairs as a binary DXF: 2-byte group codes, then each value in its binary form.
    private func binary(_ pairs: Pairs) -> Data {
        var data = Data(DXFReader.binarySentinel)
        for (code, value) in pairs + [(0, "EOF")] {
            data.append(UInt8(code & 0xFF))
            data.append(UInt8(code >> 8))
            switch DXFReader.kind(code) {
            case .number:
                let bits = (Double(value) ?? 0).bitPattern
                for k in 0..<8 { data.append(UInt8(truncatingIfNeeded: bits >> (8 * UInt64(k)))) }
            case .integer:
                let number = Int64(value) ?? 0
                for k in 0..<DXFReader.integerSize(code) { data.append(UInt8(truncatingIfNeeded: number >> (8 * Int64(k)))) }
            case .binary:
                data.append(0)
            case .text:
                data.append(contentsOf: Array(value.utf8))
                data.append(0)
            }
        }
        return data
    }
    private func drawing(_ data: Data) throws -> DXFDrawing {
        DXFDrawing(DXFDocument(try DXFReader.tags(from: data)))
    }

    private var sample: Pairs {
        var pairs: Pairs = []
        pairs += section("HEADER", [(9, "$INSUNITS"), (70, "4"), (9, "$LTSCALE"), (40, "2")])
        pairs += section("TABLES", [
            (0, "TABLE"), (2, "LTYPE"),
            (0, "LTYPE"), (2, "DASHED"), (73, "2"), (40, "1.5"), (49, "1"), (74, "0"), (49, "-0.5"), (74, "0"),
            (0, "ENDTAB"),
            (0, "TABLE"), (2, "LAYER"),
            (0, "LAYER"), (2, "PARTS"), (70, "0"), (62, "1"), (6, "DASHED"), (370, "50"),
            (0, "LAYER"), (2, "HIDDEN"), (70, "0"), (62, "-3"), (6, "CONTINUOUS"),
            (0, "ENDTAB")
        ])
        pairs += section("BLOCKS", [
            (0, "BLOCK"), (2, "BOLT"), (70, "0"), (10, "1"), (20, "1"), (30, "0"),
            (0, "CIRCLE"), (8, "0"), (10, "1"), (20, "1"), (30, "0"), (40, "1"),
            (0, "ENDBLK")
        ])
        pairs += section("ENTITIES", [
            (0, "LINE"), (8, "PARTS"), (10, "0"), (20, "0"), (30, "0"), (11, "120"), (21, "0"), (31, "0"),
            (0, "LINE"), (8, "HIDDEN"), (10, "0"), (20, "0"), (11, "5"), (21, "5"),
            (0, "ARC"), (8, "0"), (10, "50"), (20, "50"), (30, "0"), (40, "10"),
            (210, "0"), (220, "0"), (230, "-1"), (50, "0"), (51, "90"),
            (0, "LWPOLYLINE"), (8, "0"), (90, "2"), (70, "0"), (10, "0"), (20, "0"), (42, "1"), (10, "10"), (20, "0"),
            (0, "INSERT"), (8, "0"), (2, "BOLT"), (10, "30"), (20, "30"), (30, "0"), (41, "2"), (42, "2"), (43, "2"),
            (0, "LINE"), (8, "0"), (10, "0"), (20, "80"), (11, "1"), (21, "80")
        ])
        return pairs
    }

    func testLinesArcsPolylinesBlocksLayersAndLineTypes() throws {
        let model = try drawing(text(sample)).sheets[0].scene
        // The line on the hidden layer is left out.
        XCTAssertEqual(model.paths.count, 5)
        // Red, dashed with $LTSCALE 2, and 0.5 mm thick from layer PARTS.
        let line = model.paths[0]
        XCTAssertEqual(line.look.ink, DXFInk.rgb(255, 0, 0))
        XCTAssertEqual(line.look.dashes, [2, 1])
        XCTAssertEqual(line.look.weight, 1.5, accuracy: 1e-9)
        // Extrusion (0, 0, -1) mirrors the arc to the left of the Y axis.
        XCTAssertTrue(model.paths[1].points.allSatisfy { $0.x <= -49.999 && $0.x >= -60.001 && $0.y >= 49.999 })
        // Bulge 1 is a half circle below the chord from (0, 0) to (10, 0).
        XCTAssertTrue(model.paths[2].points.contains { abs($0.x - 5) < 1e-6 && abs($0.y + 5) < 1e-6 })
        // The block, scaled 2 at (30, 30) around its base point (1, 1), is a circle of radius 2 around (30, 30).
        XCTAssertTrue(model.paths[3].points.allSatisfy { abs(hypot($0.x - 30, $0.y - 30) - 2) < 1e-9 })
        XCTAssertTrue(model.paths[3].closed)
    }

    func testBinaryFilesReadLikeTextFiles() throws {
        let fromText = try drawing(text(sample)).sheets[0].scene
        let fromBinary = try drawing(binary(sample)).sheets[0].scene
        XCTAssertEqual(fromBinary.paths.count, fromText.paths.count)
        XCTAssertEqual(fromBinary.paths.map { $0.points }, fromText.paths.map { $0.points })
        XCTAssertEqual(fromBinary.paths.map { $0.look }, fromText.paths.map { $0.look })
    }

    func testSplinesAndEllipses() throws {
        let pairs = section("ENTITIES", [
            (0, "SPLINE"), (8, "0"), (70, "4"), (71, "2"), (72, "6"), (73, "3"), (74, "0"),
            (40, "0"), (40, "0"), (40, "0"), (40, "1"), (40, "1"), (40, "1"),
            (41, "1"), (41, "0.7071067811865476"), (41, "1"),
            (10, "1"), (20, "0"), (30, "0"), (10, "1"), (20, "1"), (30, "0"), (10, "0"), (20, "1"), (30, "0"),
            (0, "ELLIPSE"), (8, "0"), (10, "100"), (20, "0"), (30, "0"), (11, "10"), (21, "0"), (31, "0"),
            (40, "0.5"), (41, "0"), (42, "6.283185307179586")
        ])
        let model = try drawing(text(pairs)).sheets[0].scene
        XCTAssertEqual(model.paths.count, 2)
        // A rational quadratic spline with these weights is an exact quarter circle.
        XCTAssertTrue(model.paths[0].points.allSatisfy { abs(hypot($0.x, $0.y) - 1) < 1e-9 })
        XCTAssertEqual(model.paths[0].points.first?.x ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(model.paths[0].points.last?.y ?? 0, 1, accuracy: 1e-9)
        let ellipse = model.paths[1]
        XCTAssertTrue(ellipse.closed)
        XCTAssertEqual(ellipse.points.map { $0.x }.max() ?? 0, 110, accuracy: 1e-6)
        XCTAssertEqual(ellipse.points.map { $0.y }.max() ?? 0, 5, accuracy: 1e-6)
    }

    func testLayoutsAndTheirWindows() throws {
        var pairs: Pairs = []
        pairs += section("TABLES", [
            (0, "TABLE"), (2, "BLOCK_RECORD"),
            (0, "BLOCK_RECORD"), (5, "1F"), (2, "*Model_Space"),
            (0, "BLOCK_RECORD"), (5, "1B"), (2, "*Paper_Space"),
            (0, "ENDTAB")
        ])
        pairs += section("ENTITIES", [
            (0, "LINE"), (8, "0"), (10, "0"), (20, "0"), (11, "10"), (21, "10"),
            (0, "LINE"), (67, "1"), (8, "0"), (10, "0"), (20, "0"), (11, "297"), (21, "0"),
            (0, "VIEWPORT"), (67, "1"), (8, "0"), (10, "100"), (20, "100"), (30, "0"), (40, "100"), (41, "50"),
            (68, "1"), (69, "2"), (12, "5"), (22, "5"), (17, "0"), (27, "0"), (37, "0"), (45, "10"), (51, "0")
        ])
        pairs += section("OBJECTS", [
            (0, "LAYOUT"), (5, "1A"), (330, "D"), (100, "AcDbPlotSettings"), (1, ""), (100, "AcDbLayout"),
            (1, "Model"), (70, "1"), (71, "0"), (10, "0"), (20, "0"), (11, "420"), (21, "297"), (330, "1F"),
            (0, "LAYOUT"), (5, "1E"), (330, "D"), (100, "AcDbPlotSettings"), (1, ""), (100, "AcDbLayout"),
            (1, "Sheet A"), (70, "1"), (71, "1"), (10, "0"), (20, "0"), (11, "297"), (21, "210"), (330, "1B")
        ])
        let result = try drawing(text(pairs))
        XCTAssertEqual(result.sheets.map { $0.name }, ["Model", "Sheet A"])
        let sheet = result.sheets[1]
        XCTAssertFalse(sheet.isModel)
        XCTAssertEqual(sheet.paper?.width ?? 0, 297, accuracy: 1e-9)
        XCTAssertEqual(sheet.viewports.count, 1)
        let window = sheet.viewports[0]
        XCTAssertEqual(window.scale, 5, accuracy: 1e-9)
        XCTAssertEqual(window.paper(DXFVec(5, 5)).x, 100, accuracy: 1e-9)
        XCTAssertEqual(window.paper(DXFVec(6, 5)).x, 105, accuracy: 1e-9)
        // The sheet's own line and the window's frame.
        XCTAssertEqual(sheet.scene.paths.count, 2)
    }

    func testHatchesAndTextCodes() throws {
        let pairs = section("ENTITIES", [
            (0, "HATCH"), (8, "0"), (62, "2"), (10, "0"), (20, "0"), (30, "0"), (210, "0"), (220, "0"), (230, "1"),
            (2, "SOLID"), (70, "1"), (71, "0"), (91, "1"), (92, "3"), (72, "0"), (73, "1"), (93, "4"),
            (10, "80"), (20, "0"), (10, "100"), (20, "0"), (10, "100"), (20, "20"), (10, "80"), (20, "20"), (97, "0"),
            (75, "0"), (76, "1"), (98, "0"),
            (0, "HATCH"), (8, "0"), (10, "0"), (20, "0"), (30, "0"), (2, "ANSI31"), (70, "0"), (71, "0"),
            (91, "1"), (92, "1"), (93, "3"),
            (72, "1"), (10, "0"), (20, "0"), (11, "10"), (21, "0"),
            (72, "2"), (10, "10"), (20, "5"), (40, "5"), (50, "-90"), (51, "90"), (73, "1"),
            (72, "1"), (10, "10"), (20, "10"), (11, "0"), (21, "0"),
            (97, "0"), (75, "1"), (76, "1"), (52, "0"), (41, "0.5"), (77, "0"), (78, "1"),
            (53, "45"), (43, "0"), (44, "0"), (45, "-1"), (46, "1"), (79, "0"), (98, "0"),
            (0, "TEXT"), (8, "0"), (10, "0"), (20, "40"), (30, "0"), (40, "2.5"), (1, "%%c10 %%d %%p1"),
            (0, "MTEXT"), (8, "0"), (10, "0"), (20, "60"), (30, "0"), (40, "3"), (71, "1"),
            (1, "Line1\\PLine2 {\\fArial|b1;bold} \\S1/2;")
        ])
        let model = try drawing(text(pairs)).sheets[0].scene
        // A solid hatch is filled.
        XCTAssertEqual(model.fills.count, 1)
        XCTAssertEqual(model.fills[0].rings.first?.count, 4)
        XCTAssertEqual(model.fills[0].ink, DXFInk.rgb(255, 255, 0))
        // A patterned hatch shows its outline: a line, a half circle and a line back.
        XCTAssertEqual(model.paths.count, 1)
        XCTAssertTrue(model.paths[0].closed)
        XCTAssertTrue(model.paths[0].points.contains { abs($0.x - 15) < 1e-6 && abs($0.y - 5) < 1e-6 })
        XCTAssertEqual(model.labels.map { $0.text }, ["Ø10 ° ±1", "Line1\nLine2 bold 1/2"])
    }

    func testPicturesKeepTheirFileNameAndPlace() throws {
        var pairs: Pairs = []
        pairs += section("ENTITIES", [
            (0, "IMAGE"), (8, "0"), (10, "0"), (20, "60"), (30, "0"), (11, "0.05"), (21, "0"), (31, "0"),
            (12, "0"), (22, "0.05"), (32, "0"), (13, "640"), (23, "480"), (340, "B2"), (70, "3")
        ])
        pairs += section("OBJECTS", [
            (0, "IMAGEDEF"), (5, "B2"), (330, "B1"), (100, "AcDbRasterImageDef"), (1, "C:\\pics\\photo.jpg"),
            (10, "640"), (20, "480")
        ])
        let model = try drawing(text(pairs)).sheets[0].scene
        XCTAssertEqual(model.pictures.count, 1)
        let picture = model.pictures[0]
        XCTAssertEqual(picture.file, "photo.jpg")
        // The insertion point is the middle of the first pixel.
        XCTAssertEqual(picture.corner.x, -0.025, accuracy: 1e-9)
        XCTAssertEqual(picture.u.x, 32, accuracy: 1e-9)
        XCTAssertEqual(picture.v.y, 24, accuracy: 1e-9)
    }

    func testSizeOfTheDrawing() throws {
        XCTAssertEqual(try drawing(text(sample)).sizeText, "180 × 85 mm")
        var box = DXFBox()
        box.add(DXFVec(0, 0))
        box.add(DXFVec(4.726, 2.5))
        XCTAssertEqual(DXFDrawing.size(of: box, units: 1), "4.73 × 2.5 in")
        XCTAssertEqual(DXFDrawing.size(of: box, units: 0), "4.73 × 2.5 units")
    }

    func testLineTypePatternsAndColors() {
        // Dash, gap, dot, gap.
        XCTAssertEqual(DXFSceneBuilder.dashes([0.5, -0.25, 0, -0.25], 1).count, 4)
        // A pattern that starts with a gap starts with its dash instead.
        XCTAssertEqual(DXFSceneBuilder.dashes([-0.25, 1], 2), [2, 0.5])
        XCTAssertEqual(DXFSceneBuilder.dashes([1], 1), [])
        XCTAssertEqual(DXFInk.aci(20), DXFInk.rgb(255, 63, 0))
        XCTAssertEqual(DXFInk.aci(21), DXFInk.rgb(255, 159, 127))
        XCTAssertEqual(DXFInk.aci(7), DXFInk.foreground)
    }
}
