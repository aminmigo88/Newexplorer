import Foundation
import ZIPFoundation

// 3D models for the 3D view: STL, 3MF, STEP and IGES files read here, and a DXF drawing's main part turned into 3D.
// OBJ files go through Apple's Model I/O (Model3DView.swift).

struct Model3D {
    // More triangles than this would use too much memory on a phone.
    static let maxTriangles = 6_000_000

    // Triangles: x, y and z of each corner, three corners per triangle.
    struct Surface {
        var positions: [Float]
        // nil: the default model color.
        var ink: DXFInk?
    }
    // Line segments (two ends each) or points: x, y and z of each.
    struct Lines {
        var positions: [Float]
        var ink: DXFInk
    }
    var surfaces: [Surface] = []
    var lines: [Lines] = []
    var points: [Lines] = []
    var flats: [DXFFill] = []
    var labels: [DXFLabel] = []
    var pictures: [DXFPicture] = []
    // Taken off a drawing's coordinates before they became Float, so drawings far from 0 stay precise.
    // Fills, text and pictures keep the drawing's coordinates, so it's taken off them when they're shown.
    var offset = DXFVec()
    // Z points up in STL, 3MF and DXF files.
    var zUp = true

    var triangleCount: Int { surfaces.reduce(0) { $0 + $1.positions.count / 9 } }
    var isEmpty: Bool {
        triangleCount == 0 && lines.isEmpty && points.isEmpty && flats.isEmpty && labels.isEmpty && pictures.isEmpty
    }

    // The box around everything, after the offset.
    var extent: (low: DXFVec, high: DXFVec) {
        var low = DXFVec(.infinity, .infinity, .infinity)
        var high = DXFVec(-.infinity, -.infinity, -.infinity)
        func include(_ p: DXFVec) {
            guard p.x.isFinite, p.y.isFinite, p.z.isFinite else { return }
            low = DXFVec(min(low.x, p.x), min(low.y, p.y), min(low.z, p.z))
            high = DXFVec(max(high.x, p.x), max(high.y, p.y), max(high.z, p.z))
        }
        func includeAll(_ positions: [Float]) {
            var k = 0
            while k + 2 < positions.count {
                include(DXFVec(Double(positions[k]), Double(positions[k + 1]), Double(positions[k + 2])))
                k += 3
            }
        }
        for surface in surfaces { includeAll(surface.positions) }
        for group in lines + points { includeAll(group.positions) }
        for fill in flats { for ring in fill.rings { for point in ring { include(point - offset) } } }
        for label in labels { include(label.origin - offset) }
        for picture in pictures {
            include(picture.corner - offset)
            include(picture.corner + picture.u + picture.v - offset)
        }
        return low.x <= high.x ? (low: low, high: high) : (low: DXFVec(), high: DXFVec())
    }
}

extension Model3D {
    // A DXF drawing's main part in 3D: lines, faces, fills, dots, text and pictures, around its center.
    init(dxf scene: DXFScene) {
        var low = DXFVec(.infinity, .infinity, .infinity)
        var high = DXFVec(-.infinity, -.infinity, -.infinity)
        func include(_ p: DXFVec) {
            guard p.x.isFinite, p.y.isFinite, p.z.isFinite else { return }
            low = DXFVec(min(low.x, p.x), min(low.y, p.y), min(low.z, p.z))
            high = DXFVec(max(high.x, p.x), max(high.y, p.y), max(high.z, p.z))
        }
        for path in scene.paths { for point in path.points { include(point) } }
        for face in scene.faces { for point in face.corners { include(point) } }
        for fill in scene.fills { for ring in fill.rings { for point in ring { include(point) } } }
        for dot in scene.dots { include(dot.point) }
        for label in scene.labels { include(label.origin) }
        for picture in scene.pictures {
            include(picture.corner)
            include(picture.corner + picture.u + picture.v)
        }
        let center = low.x <= high.x
            ? DXFVec((low.x + high.x) / 2, (low.y + high.y) / 2, (low.z + high.z) / 2) : DXFVec()
        offset = center

        var lineGroups: [DXFInk: [Float]] = [:]
        for path in scene.paths where path.points.count >= 2 {
            let count = path.points.count
            let segments = path.closed ? count : count - 1
            for i in 0..<segments {
                Self.append(path.points[i], center, to: &lineGroups[path.look.ink, default: []])
                Self.append(path.points[(i + 1) % count], center, to: &lineGroups[path.look.ink, default: []])
            }
        }
        lines = lineGroups.map { Lines(positions: $0.value, ink: $0.key) }

        var faceGroups: [DXFInk: [Float]] = [:]
        for face in scene.faces where face.corners.count >= 3 {
            // Faces are flat, so a fan of triangles from the first corner covers them.
            for k in 1..<(face.corners.count - 1) {
                Self.append(face.corners[0], center, to: &faceGroups[face.ink, default: []])
                Self.append(face.corners[k], center, to: &faceGroups[face.ink, default: []])
                Self.append(face.corners[k + 1], center, to: &faceGroups[face.ink, default: []])
            }
        }
        surfaces = faceGroups.map { Surface(positions: $0.value, ink: $0.key) }

        var dotGroups: [DXFInk: [Float]] = [:]
        for dot in scene.dots { Self.append(dot.point, center, to: &dotGroups[dot.ink, default: []]) }
        points = dotGroups.map { Lines(positions: $0.value, ink: $0.key) }

        flats = scene.fills
        labels = scene.labels
        pictures = scene.pictures
    }

    private static func append(_ p: DXFVec, _ center: DXFVec, to positions: inout [Float]) {
        positions.append(Float(p.x - center.x))
        positions.append(Float(p.y - center.y))
        positions.append(Float(p.z - center.z))
    }
}

// STL files, binary and text: a list of triangles.
enum STLReader {
    static func read(_ data: Data) throws -> [Float] {
        let size = data.count
        var declared = -1
        if size >= 84 {
            declared = data.withUnsafeBytes { raw in
                Int(UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: 80, as: UInt32.self)))
            }
        }
        // A binary file is 84 bytes plus 50 per triangle. Some binary files start with "solid" like text ones.
        let fitsBinary = declared >= 0 && size >= 84 + declared * 50
        let saysSolid = String(decoding: data.prefix(5), as: UTF8.self).lowercased() == "solid"
        if declared >= 0 && size == 84 + declared * 50 { return try binary(data, triangles: declared) }
        if !saysSolid && fitsBinary && declared > 0 { return try binary(data, triangles: declared) }
        let positions = try text(data)
        if !positions.isEmpty { return positions }
        if fitsBinary && declared > 0 { return try binary(data, triangles: declared) }
        throw ExplorerError("This STL file has no triangles.")
    }

    private static func binary(_ data: Data, triangles: Int) throws -> [Float] {
        guard triangles <= Model3D.maxTriangles else { throw tooMany }
        var positions = [Float](repeating: 0, count: triangles * 9)
        data.withUnsafeBytes { raw in
            for t in 0..<triangles {
                // Each triangle: its normal, three corners, then 2 spare bytes.
                let base = 84 + t * 50 + 12
                for k in 0..<9 {
                    let bits = raw.loadUnaligned(fromByteOffset: base + k * 4, as: UInt32.self)
                    let value = Float(bitPattern: UInt32(littleEndian: bits))
                    positions[t * 9 + k] = value.isFinite ? value : 0
                }
            }
        }
        return positions
    }

    // Text files: the three numbers after each "vertex" word.
    private static func text(_ data: Data) throws -> [Float] {
        var positions: [Float] = []
        var overflow = false
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            let count = bytes.count
            var i = 0
            var expecting = 0
            while i < count {
                let c = bytes[i]
                if c == 32 || c == 9 || c == 10 || c == 13 {
                    i += 1
                    continue
                }
                let start = i
                while i < count {
                    let d = bytes[i]
                    if d == 32 || d == 9 || d == 10 || d == 13 { break }
                    i += 1
                }
                let word = UnsafeBufferPointer(rebasing: bytes[start..<i])
                if expecting > 0 {
                    let number = Float(String(decoding: word, as: UTF8.self)) ?? 0
                    positions.append(number.isFinite ? number : 0)
                    expecting -= 1
                } else if word.count == 6, String(decoding: word, as: UTF8.self).lowercased() == "vertex" {
                    if positions.count >= Model3D.maxTriangles * 9 {
                        overflow = true
                        return
                    }
                    expecting = 3
                }
            }
        }
        if overflow { throw tooMany }
        positions.removeLast(positions.count % 9)
        return positions
    }

    private static var tooMany: ExplorerError { ExplorerError("This model has too many triangles to show here (over 6 million).") }
}

// STEP and IGES files (CAD), read and turned into triangles by Open CASCADE Technology (CADMesh.cpp).
// Edges that aren't part of a surface, such as IGES wireframes, come back as lines.
enum CADReader {
    static func read(_ url: URL) throws -> Model3D {
        let iges = ["iges", "igs"].contains(url.pathExtension.lowercased())
        guard let result = CADMeshRead(url.path, iges ? 1 : 0, Model3D.maxTriangles) else {
            throw ExplorerError("There isn’t enough memory to show this model.")
        }
        defer { CADMeshFree(result) }
        let mesh = result.pointee
        switch mesh.status {
        case 0: break
        case 2: throw ExplorerError("This file has no shapes to show.")
        case 3: throw ExplorerError("This model has too many triangles to show here (over 6 million).")
        case 4: throw ExplorerError("There isn’t enough memory to show this model.")
        default: throw ExplorerError(iges ? "This IGES file can’t be read." : "This STEP file can’t be read.")
        }
        var model = Model3D()
        if let triangles = mesh.triangles, mesh.triangleFloats > 0 {
            let positions = Array(UnsafeBufferPointer(start: triangles, count: mesh.triangleFloats))
            model.surfaces = [Model3D.Surface(positions: positions, ink: nil)]
        }
        if let lines = mesh.lines, mesh.lineFloats > 0 {
            let positions = Array(UnsafeBufferPointer(start: lines, count: mesh.lineFloats))
            model.lines = [Model3D.Lines(positions: positions, ink: .foreground)]
        }
        return model
    }
}

// 3MF files (3D printing): a ZIP with XML model files. Objects can be built from components in other model files,
// as Bambu Studio and PrusaSlicer write them; colors come from base materials and color groups.
enum ThreeMFReader {
    static func read(_ url: URL) throws -> [Model3D.Surface] {
        let archive: Archive
        do { archive = try Archive(url: url, accessMode: .read) } catch { throw ExplorerError("This 3MF file can’t be opened.") }
        func contents(_ path: String) -> Data? {
            let name = path.hasPrefix("/") ? String(path.dropFirst()) : path
            guard let item = archive[name] else { return nil }
            var data = Data()
            do { _ = try archive.extract(item, consumer: { data.append($0) }) } catch { return nil }
            return data
        }
        var parts: [String: ThreeMFPart] = [:]
        func part(_ path: String) -> ThreeMFPart? {
            let name = path.hasPrefix("/") ? String(path.dropFirst()) : path
            if let known = parts[name] { return known }
            guard let data = contents(name) else { return nil }
            let parsed = ThreeMFPart(data)
            parts[name] = parsed
            return parsed
        }
        // The relationships file names the main model file.
        let root = contents("_rels/.rels").flatMap { ThreeMFRelations($0).model } ?? "3D/3dmodel.model"
        guard let model = part(root) else { throw ExplorerError("This 3MF file has no 3D model in it.") }

        var groups: [DXFInk?: [Float]] = [:]
        var triangles = 0
        var overflow = false
        func add(_ objectID: String, in file: String, _ transform: DXFMatrix, depth: Int) {
            guard depth < 16, !overflow, let source = part(file), let object = source.objects[objectID] else { return }
            if !object.triangles.isEmpty {
                // Each corner placed once, then the triangles use them.
                let vertexCount = object.vertices.count / 3
                var placed = [Float](repeating: 0, count: vertexCount * 3)
                for index in 0..<vertexCount {
                    let corner = transform.apply(DXFVec(Double(object.vertices[index * 3]), Double(object.vertices[index * 3 + 1]),
                                                        Double(object.vertices[index * 3 + 2])))
                    placed[index * 3] = Float(corner.x)
                    placed[index * 3 + 1] = Float(corner.y)
                    placed[index * 3 + 2] = Float(corner.z)
                }
                for triangle in object.triangles {
                    guard triangle.a >= 0, triangle.b >= 0, triangle.c >= 0,
                          triangle.a < vertexCount, triangle.b < vertexCount, triangle.c < vertexCount else { continue }
                    if triangles >= Model3D.maxTriangles {
                        overflow = true
                        return
                    }
                    let a = triangle.a * 3, b = triangle.b * 3, c = triangle.c * 3
                    groups[triangle.ink, default: []].append(contentsOf: [placed[a], placed[a + 1], placed[a + 2],
                                                                          placed[b], placed[b + 1], placed[b + 2],
                                                                          placed[c], placed[c + 1], placed[c + 2]])
                    triangles += 1
                }
            }
            for component in object.components {
                add(component.object, in: component.path ?? file, transform * component.transform, depth: depth + 1)
            }
        }
        for item in model.items { add(item.object, in: root, item.transform, depth: 0) }
        if overflow { throw ExplorerError("This model has too many triangles to show here (over 6 million).") }
        return groups.map { Model3D.Surface(positions: $0.value, ink: $0.key) }
    }
}

// The relationships file of a 3MF: which file holds the model.
final class ThreeMFRelations: NSObject, XMLParserDelegate {
    private(set) var model: String?

    init(_ data: Data) {
        super.init()
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.parse()
    }
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        guard model == nil, elementName.hasSuffix("Relationship"),
              let target = attributeDict["Target"], let type = attributeDict["Type"], type.hasSuffix("/3dmodel") else { return }
        model = target
    }
}

// One model file inside a 3MF: its objects (meshes or components), colors and build items.
final class ThreeMFPart: NSObject, XMLParserDelegate {
    struct Triangle {
        let a: Int
        let b: Int
        let c: Int
        let ink: DXFInk?
    }
    struct Component {
        let object: String
        let path: String?
        let transform: DXFMatrix
    }
    struct Shape {
        var vertices: [Float] = []
        var triangles: [Triangle] = []
        var components: [Component] = []
        var group: String?
        var ink: DXFInk?
    }
    struct Item {
        let object: String
        let transform: DXFMatrix
    }
    private struct ColorList {
        let id: String
        var inks: [DXFInk] = []
    }
    private(set) var objects: [String: Shape] = [:]
    private(set) var items: [Item] = []
    private var colors: [String: [DXFInk]] = [:]
    private var openColors: ColorList?
    private var openObject: String?
    private var shape = Shape()

    init(_ data: Data) {
        super.init()
        let parser = XMLParser(data: data)
        parser.delegate = self
        parser.shouldProcessNamespaces = true
        parser.parse()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        switch elementName {
        case "basematerials", "colorgroup":
            openColors = ColorList(id: attributeDict["id"] ?? "")
        case "base":
            openColors?.inks.append(Self.color(attributeDict["displaycolor"]) ?? .rgb(200, 200, 200))
        case "color":
            openColors?.inks.append(Self.color(attributeDict["color"]) ?? .rgb(200, 200, 200))
        case "object":
            openObject = attributeDict["id"]
            shape = Shape()
            shape.group = attributeDict["pid"]
            shape.ink = ink(attributeDict["pid"], attributeDict["pindex"])
        case "vertex":
            shape.vertices.append(Float(attributeDict["x"] ?? "") ?? 0)
            shape.vertices.append(Float(attributeDict["y"] ?? "") ?? 0)
            shape.vertices.append(Float(attributeDict["z"] ?? "") ?? 0)
        case "triangle":
            guard let a = Int(attributeDict["v1"] ?? ""), let b = Int(attributeDict["v2"] ?? ""),
                  let c = Int(attributeDict["v3"] ?? "") else { return }
            // A triangle's own color, or its object's.
            let own = attributeDict["p1"] != nil ? ink(attributeDict["pid"] ?? shape.group, attributeDict["p1"]) : nil
            shape.triangles.append(Triangle(a: a, b: b, c: c, ink: own ?? shape.ink))
        case "component":
            guard let id = attributeDict["objectid"] else { return }
            let path = attributeDict.first(where: { $0.key == "path" || $0.key.hasSuffix(":path") })?.value
            shape.components.append(Component(object: id, path: path, transform: Self.transform(attributeDict["transform"])))
        case "item":
            guard let id = attributeDict["objectid"] else { return }
            items.append(Item(object: id, transform: Self.transform(attributeDict["transform"])))
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        switch elementName {
        case "object":
            if let id = openObject { objects[id] = shape }
            openObject = nil
            shape = Shape()
        case "basematerials", "colorgroup":
            if let list = openColors { colors[list.id] = list.inks }
            openColors = nil
        default:
            break
        }
    }

    private func ink(_ group: String?, _ index: String?) -> DXFInk? {
        guard let group, let list = colors[group] else { return nil }
        let position = Int(index ?? "0") ?? 0
        return list.indices.contains(position) ? list[position] : nil
    }

    // "#RRGGBB" or "#RRGGBBAA".
    static func color(_ text: String?) -> DXFInk? {
        guard var hex = text?.trimmingCharacters(in: .whitespaces) else { return nil }
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6 || hex.count == 8, let value = Int(hex.prefix(6), radix: 16) else { return nil }
        return .trueColor(value)
    }

    // A 3MF transform lists 12 numbers, row by row: where the three axes go, then the shift.
    static func transform(_ text: String?) -> DXFMatrix {
        guard let text else { return .identity }
        let v = text.split(whereSeparator: { $0.isWhitespace }).compactMap { Double($0) }
        guard v.count == 12 else { return .identity }
        return DXFMatrix(ax: DXFVec(v[0], v[1], v[2]), ay: DXFVec(v[3], v[4], v[5]), az: DXFVec(v[6], v[7], v[8]),
                         t: DXFVec(v[9], v[10], v[11]))
    }
}
