import Foundation

// What a DXF drawing shows, in drawing coordinates: lines, fills, dots, text and pictures,
// with blocks placed, colors, line types and line weights resolved, and hidden layers left out.

struct DXFLook: Hashable {
    var ink: DXFInk
    // On-screen thickness in points for a line weight; 0 is a thin line.
    var weight: Double
    // Dash and gap lengths in drawing units, starting with a dash; empty is a solid line.
    var dashes: [Double]
}

struct DXFPath {
    var points: [DXFVec]
    var closed: Bool
    var look: DXFLook
    // A polyline's own width in drawing units; 0 when it has none.
    var width: Double
    var layer: String
}

struct DXFFill {
    var rings: [[DXFVec]]
    var ink: DXFInk
    var layer: String
}

struct DXFDot {
    var point: DXFVec
    var ink: DXFInk
    var layer: String
}

// A flat face of a 3D surface (3D faces and meshes); the 2D view draws its edges, the 3D view the face.
struct DXFFace {
    var corners: [DXFVec]
    var ink: DXFInk
    var layer: String
}

// Text: its lines, where it sits and which way it runs, in the drawing's units.
struct DXFLabel {
    var text: String
    var origin: DXFVec
    var xAxis: DXFVec
    var yAxis: DXFVec
    var height: Double
    var widthFactor: Double
    // 0 left, 1 center, 2 right.
    var horizontal: Int
    // 0 baseline, 1 bottom, 2 middle, 3 top.
    var vertical: Int
    // Width multi-line text wraps at; 0 for none.
    var wrap: Double
    var spacing: Double
    // Length "fit" and "aligned" text is stretched to; 0 for none. Aligned text also grows in height.
    var fit: Double
    var stretch: Bool
    var ink: DXFInk
    var layer: String
}

// A picture: its file name, and its corner and sides in the drawing.
struct DXFPicture {
    var file: String
    var corner: DXFVec
    var u: DXFVec
    var v: DXFVec
    var layer: String
    var ink: DXFInk
}

struct DXFBox {
    var minX = Double.infinity
    var minY = Double.infinity
    var maxX = -Double.infinity
    var maxY = -Double.infinity

    var isEmpty: Bool { minX > maxX || minY > maxY }
    var width: Double { isEmpty ? 0 : maxX - minX }
    var height: Double { isEmpty ? 0 : maxY - minY }
    mutating func add(_ p: DXFVec) {
        guard p.x.isFinite, p.y.isFinite else { return }
        minX = min(minX, p.x)
        minY = min(minY, p.y)
        maxX = max(maxX, p.x)
        maxY = max(maxY, p.y)
    }
    mutating func add(_ box: DXFBox) {
        guard !box.isEmpty else { return }
        add(DXFVec(box.minX, box.minY))
        add(DXFVec(box.maxX, box.maxY))
    }
}

struct DXFScene {
    var paths: [DXFPath] = []
    var fills: [DXFFill] = []
    var dots: [DXFDot] = []
    var faces: [DXFFace] = []
    var labels: [DXFLabel] = []
    var pictures: [DXFPicture] = []
    var box = DXFBox()

    var isEmpty: Bool {
        paths.isEmpty && fills.isEmpty && dots.isEmpty && faces.isEmpty && labels.isEmpty && pictures.isEmpty
    }
}

// A window in a layout onto the main drawing, seen from the top.
struct DXFViewport {
    var center: DXFVec
    var width: Double
    var height: Double
    var viewCenter: DXFVec
    var viewHeight: Double
    var target: DXFVec
    var twist: Double
    var hidden: Set<String>

    var scale: Double { viewHeight > 0 ? height / viewHeight : 1 }
    // Where a point of the main drawing appears on the sheet.
    func paper(_ p: DXFVec) -> DXFVec {
        let dx = p.x - target.x, dy = p.y - target.y
        let c = cos(-twist), s = sin(-twist)
        let x = dx * c - dy * s, y = dx * s + dy * c
        return DXFVec(center.x + (x - viewCenter.x) * scale, center.y + (y - viewCenter.y) * scale)
    }
}

// What the viewer can show: the main drawing, or one layout with its windows.
struct DXFSheet {
    var name: String
    var isModel: Bool
    var scene: DXFScene
    var viewports: [DXFViewport]
    var paper: DXFBox?
    var box: DXFBox
}

struct DXFDrawing {
    var sheets: [DXFSheet]
    var model: DXFScene
    var units: Int
    // The main drawing's size, such as "120 × 80 mm".
    var sizeText: String?

    static func handles(_ name: String) -> Bool { (name as NSString).pathExtension.lowercased() == "dxf" }

    static func load(_ url: URL) throws -> DXFDrawing {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        if size > 150_000_000 { throw ExplorerError("This DXF file is too big to show (over 150 MB).") }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let tags = try DXFReader.tags(from: data)
        guard tags.contains(where: { $0.code == 0 }) else { throw ExplorerError("This file isn’t a DXF drawing.") }
        let document = DXFDocument(tags)
        let drawing = DXFDrawing(document)
        if drawing.sheets.allSatisfy({ $0.scene.isEmpty && $0.viewports.isEmpty }) {
            if document.hasSolids { throw ExplorerError("This drawing only has 3D solids, which can’t be shown.") }
            throw ExplorerError("This drawing is empty.")
        }
        return drawing
    }

    init(_ document: DXFDocument) {
        var builder = DXFSceneBuilder(document)
        let model = builder.build(document.model)
        var sheets = [DXFSheet(name: "Model", isModel: true, scene: model, viewports: [], paper: nil, box: model.box)]
        for layout in document.layouts {
            let scene = builder.build(layout.entities)
            let viewports = layout.entities.compactMap { DXFSceneBuilder.viewport($0, document) }
            var box = scene.box
            var paper: DXFBox?
            if let low = layout.low, let high = layout.high {
                var sheet = DXFBox()
                sheet.add(low)
                sheet.add(high)
                paper = sheet
                box.add(sheet)
            }
            for viewport in viewports {
                box.add(DXFVec(viewport.center.x - viewport.width / 2, viewport.center.y - viewport.height / 2))
                box.add(DXFVec(viewport.center.x + viewport.width / 2, viewport.center.y + viewport.height / 2))
            }
            guard !box.isEmpty else { continue }
            sheets.append(DXFSheet(name: layout.name, isModel: false, scene: scene, viewports: viewports, paper: paper, box: box))
        }
        // A drawing with nothing in its main part opens on its first layout.
        if model.isEmpty && sheets.count > 1 { sheets.removeFirst() }
        self.sheets = sheets
        self.model = model
        units = document.units
        sizeText = model.isEmpty ? nil : Self.size(of: model.box, units: document.units)
    }

    static func size(of box: DXFBox, units: Int) -> String? {
        guard !box.isEmpty else { return nil }
        let symbols: [Int: String] = [1: "in", 2: "ft", 3: "mi", 4: "mm", 5: "cm", 6: "m", 7: "km", 8: "µin", 9: "mil",
                                      10: "yd", 11: "Å", 12: "nm", 13: "µm", 14: "dm", 15: "dam", 16: "hm", 17: "Gm",
                                      18: "AU", 19: "ly", 20: "pc"]
        return number(box.width) + " × " + number(box.height) + " " + (symbols[units] ?? "units")
    }
    static func number(_ value: Double) -> String {
        var text = String(format: "%.2f", value)
        while text.contains(".") && (text.hasSuffix("0") || text.hasSuffix(".")) { text.removeLast() }
        return text
    }
}

// Turns entities into a scene, placing blocks and resolving what each entity inherits.
struct DXFSceneBuilder {
    private struct Inherited {
        var layer: String?
        var ink = DXFInk.foreground
        var lineType = "CONTINUOUS"
        var weight = -3
        var lineTypeScale = 1.0
    }
    private struct Properties {
        var layer: String
        var ink: DXFInk
        var look: DXFLook
        var visible: Bool
        var frozen: Bool
        var lineType: String
        var weight: Int
        var lineTypeScale: Double

        var inherited: Inherited {
            Inherited(layer: layer, ink: ink, lineType: lineType, weight: weight, lineTypeScale: lineTypeScale)
        }
    }
    private struct Endless {
        var origin: DXFVec
        var direction: DXFVec
        var ray: Bool
        var look: DXFLook
        var layer: String
    }
    // Reads hatch boundaries tag by tag.
    private struct Cursor {
        let tags: [DXFTag]
        var index: Int

        var code: Int? { index < tags.count ? tags[index].code : nil }
        mutating func take(_ code: Int) -> DXFTag? {
            guard index < tags.count, tags[index].code == code else { return nil }
            index += 1
            return tags[index - 1]
        }
        mutating func double(_ code: Int) -> Double? { take(code)?.double }
        mutating func int(_ code: Int) -> Int? { take(code)?.int }
    }

    private let document: DXFDocument
    private var scene = DXFScene()
    private var chain: [String] = []
    private var endless: [Endless] = []

    init(_ document: DXFDocument) { self.document = document }

    mutating func build(_ entities: [DXFEntity]) -> DXFScene {
        scene = DXFScene()
        chain = []
        endless = []
        add(entities, DXFMatrix.identity, Inherited())
        // Lines without ends (XLINE, RAY) run across everything else.
        var box = scene.box
        if box.isEmpty { for line in endless { box.add(line.origin) } }
        if !box.isEmpty {
            let centerX = (box.minX + box.maxX) / 2, centerY = (box.minY + box.maxY) / 2
            let diagonal = (box.width * box.width + box.height * box.height).squareRoot()
            for line in endless {
                let direction = line.direction.unit
                guard direction.length > 0 else { continue }
                let reach = (diagonal + hypot(line.origin.x - centerX, line.origin.y - centerY)) * 1.2 + 1
                let start = line.ray ? line.origin : line.origin - direction * reach
                let end = line.origin + direction * reach
                scene.paths.append(DXFPath(points: [start, end], closed: false, look: line.look, width: 0, layer: line.layer))
            }
        }
        return scene
    }

    private mutating func add(_ entities: [DXFEntity], _ m: DXFMatrix, _ inherited: Inherited) {
        for entity in entities { add(entity, m, inherited) }
    }

    private mutating func add(_ e: DXFEntity, _ m: DXFMatrix, _ inherited: Inherited) {
        let p = properties(e, m, inherited)
        switch e.type {
        case "INSERT":
            insert(e, m, p)
        case "ACAD_TABLE":
            table(e, m, p)
        case "DIMENSION", "ARC_DIMENSION", "LARGE_RADIAL_DIMENSION":
            dimension(e, m, p)
        default:
            guard p.visible else { return }
            switch e.type {
            case "LINE": stroke([m.apply(e.point(10)), m.apply(e.point(11))], closed: false, p)
            case "POINT": dot(m.apply(e.point(10)), p)
            case "CIRCLE", "ARC": circle(e, m, p)
            case "ELLIPSE": ellipse(e, m, p)
            case "LWPOLYLINE": lightPolyline(e, m, p)
            case "POLYLINE": polyline(e, m, p)
            case "SPLINE": spline(e, m, p)
            case "TEXT", "ATTRIB": text(e, m, p)
            case "MTEXT": mtext(e, m, p)
            case "SOLID", "TRACE": solid(e, m, p)
            case "3DFACE": face(e, m, p)
            case "MESH": mesh(e, m, p)
            case "HATCH": hatch(e, m, p)
            case "IMAGE": image(e, m, p)
            case "LEADER": sequence(e, m, p, code: 10, closed: false)
            case "MLINE": sequence(e, m, p, code: 11, closed: e.int(71) & 2 != 0)
            case "XLINE", "RAY":
                endless.append(Endless(origin: m.apply(e.point(10)), direction: m.vector(e.point(11)), ray: e.type == "RAY",
                                       look: p.look, layer: p.layer))
            case "VIEWPORT": viewportFrame(e, p)
            default: break
            }
        }
    }

    // Layer, color, line type and line weight, including what a block's parts take from the block reference.
    private func properties(_ e: DXFEntity, _ m: DXFMatrix, _ inherited: Inherited) -> Properties {
        var layerName = e.string(8, "0").uppercased()
        // Parts of a block on layer 0 take the layer of the block reference.
        if layerName == "0", let outer = inherited.layer { layerName = outer }
        let layer = document.layers[layerName] ?? DXFLayer()
        var ink: DXFInk
        if let trueColor = e.tag(420) {
            ink = .trueColor(trueColor.int)
        } else {
            let index = e.int(62, 256)
            switch index {
            case 0: ink = inherited.ink
            case 1...255: ink = .aci(index)
            default: ink = layer.ink
            }
        }
        var lineType = e.string(6, "BYLAYER").uppercased()
        if lineType == "BYLAYER" { lineType = layer.lineType } else if lineType == "BYBLOCK" { lineType = inherited.lineType }
        var weight = e.int(370, -1)
        if weight == -1 { weight = layer.weight } else if weight == -2 { weight = inherited.weight }
        let typeScale = e.double(48, 1) * inherited.lineTypeScale
        let dashScale = typeScale * document.lineTypeScale * m.lengthScale
        let look = DXFLook(ink: ink, weight: Self.points(weight), dashes: Self.dashes(document.lineTypes[lineType] ?? [], dashScale))
        let invisible = e.int(60) == 1
        return Properties(layer: layerName, ink: ink, look: look, visible: !layer.off && !layer.frozen && !invisible,
                          frozen: layer.frozen || invisible, lineType: lineType, weight: weight, lineTypeScale: typeScale)
    }

    // A line weight in hundredths of a millimetre as on-screen points; up to 0.25 mm is a thin line, as in AutoCAD.
    static func points(_ weight: Int) -> Double {
        guard weight > 25 else { return 0 }
        return Double(weight) / 100 / 0.25 * 0.75
    }

    // A line type's pattern as dash and gap lengths, starting with a dash. A 0 is a dot.
    static func dashes(_ pattern: [Double], _ scale: Double) -> [Double] {
        guard scale > 0, pattern.count >= 2, pattern.contains(where: { $0 < 0 }) else { return [] }
        let total = pattern.reduce(0) { $0 + abs($1) }
        guard total > 0 else { return [] }
        var parts: [(on: Bool, length: Double)] = []
        for value in pattern {
            let on = value >= 0
            let length = on ? max(value, total * 0.001) : -value
            if let last = parts.last, last.on == on {
                parts[parts.count - 1].length += length
            } else {
                parts.append((on: on, length: length))
            }
        }
        // The pattern repeats, so a part at the end joins one of the same kind at the start.
        if parts.count > 1, parts[0].on == parts[parts.count - 1].on {
            let last = parts.removeLast()
            parts[0].length += last.length
        }
        if let first = parts.first, !first.on { parts.append(parts.removeFirst()) }
        guard parts.count >= 2 else { return [] }
        return parts.map { $0.length * scale }
    }

    // MARK: Adding to the scene

    private mutating func stroke(_ points: [DXFVec], closed: Bool, _ p: Properties, width: Double = 0) {
        guard points.count >= 2 else { return }
        for point in points { scene.box.add(point) }
        scene.paths.append(DXFPath(points: points, closed: closed, look: p.look, width: width, layer: p.layer))
    }

    private mutating func fill(_ rings: [[DXFVec]], _ p: Properties) {
        let usable = rings.filter { $0.count >= 3 }
        guard !usable.isEmpty else { return }
        for ring in usable { for point in ring { scene.box.add(point) } }
        scene.fills.append(DXFFill(rings: usable, ink: p.ink, layer: p.layer))
    }

    private mutating func face(_ corners: [DXFVec], _ p: Properties) {
        var kept: [DXFVec] = []
        for corner in corners where kept.last != corner { kept.append(corner) }
        if kept.count > 1 && kept.first == kept.last { kept.removeLast() }
        guard kept.count >= 3 else { return }
        for corner in kept { scene.box.add(corner) }
        scene.faces.append(DXFFace(corners: kept, ink: p.ink, layer: p.layer))
    }

    private mutating func dot(_ point: DXFVec, _ p: Properties) {
        scene.box.add(point)
        scene.dots.append(DXFDot(point: point, ink: p.ink, layer: p.layer))
    }

    // Text counts toward the drawing's size with an estimate of its extent.
    private mutating func addLabel(_ label: DXFLabel) {
        let lines = label.text.split(separator: "\n", omittingEmptySubsequences: false)
        let longest = Double(lines.map { $0.count }.max() ?? 0)
        var width = longest * 0.6 * label.height * label.widthFactor
        if label.wrap > 0 { width = min(width, label.wrap) }
        if label.fit > 0 { width = label.fit }
        let lineHeight = label.height * 5 / 3 * label.spacing
        let height = label.height + Double(max(lines.count - 1, 0)) * lineHeight
        let left: Double = label.horizontal == 1 ? -width / 2 : (label.horizontal == 2 ? -width : 0)
        let bottom: Double
        switch label.vertical {
        case 3: bottom = -height
        case 2: bottom = -height / 2
        case 1: bottom = 0
        default: bottom = label.height - height
        }
        for (dx, dy) in [(left, bottom), (left + width, bottom), (left, bottom + height), (left + width, bottom + height)] {
            let along = label.xAxis * dx
            let up = label.yAxis * dy
            scene.box.add(label.origin + along + up)
        }
        scene.labels.append(label)
    }

    // MARK: Entities

    private mutating func circle(_ e: DXFEntity, _ m: DXFMatrix, _ p: Properties) {
        let radius = e.double(40)
        guard radius > 0 else { return }
        let place = m * DXFMatrix.ocs(e.normal())
        let full = e.type == "CIRCLE"
        let start = full ? 0 : e.double(50) * Double.pi / 180
        let end = full ? 2 * Double.pi : Self.after(start, e.double(51) * Double.pi / 180)
        var points = Self.arc(e.point(10), radius, start, end)
        if full { points.removeLast() }
        stroke(points.map { place.apply($0) }, closed: full, p)
    }

    private mutating func ellipse(_ e: DXFEntity, _ m: DXFMatrix, _ p: Properties) {
        let center = e.point(10)
        let major = e.point(11)
        guard major.length > 0 else { return }
        let minor = e.normal().unit.cross(major).unit * (major.length * e.double(40, 1))
        let start = e.double(41, 0)
        let end = Self.after(start, e.double(42, 2 * Double.pi))
        let full = abs(end - start - 2 * Double.pi) < 1e-9
        let count = Self.steps(end - start)
        var points: [DXFVec] = []
        points.reserveCapacity(count + 1)
        for i in 0...count {
            let t = start + (end - start) * Double(i) / Double(count)
            let c = cos(t), s = sin(t)
            points.append(m.apply(DXFVec(center.x + major.x * c + minor.x * s,
                                         center.y + major.y * c + minor.y * s,
                                         center.z + major.z * c + minor.z * s)))
        }
        if full { points.removeLast() }
        stroke(points, closed: full, p)
    }

    private mutating func lightPolyline(_ e: DXFEntity, _ m: DXFMatrix, _ p: Properties) {
        let elevation = e.double(38)
        var points: [DXFVec] = []
        var bulges: [Double] = []
        var widths: [Double] = []
        for tag in e.tags {
            switch tag.code {
            case 10:
                points.append(DXFVec(tag.double, 0, elevation))
                bulges.append(0)
            case 20:
                if !points.isEmpty { points[points.count - 1].y = tag.double }
            case 40, 41:
                if !points.isEmpty && tag.double > 0 { widths.append(tag.double) }
            case 42:
                if !bulges.isEmpty { bulges[bulges.count - 1] = tag.double }
            default:
                break
            }
        }
        let closed = e.int(70) & 1 != 0
        let place = m * DXFMatrix.ocs(e.normal())
        let constant = e.double(43)
        let width = constant > 0 ? constant : (widths.isEmpty ? 0 : widths.reduce(0, +) / Double(widths.count))
        stroke(Self.bulged(points, bulges, closed: closed).map { place.apply($0) }, closed: closed, p, width: width * place.lengthScale)
    }

    private mutating func polyline(_ e: DXFEntity, _ m: DXFMatrix, _ p: Properties) {
        let flags = e.int(70)
        let vertices = e.children.filter { $0.type == "VERTEX" }
        if flags & 64 != 0 {
            polyface(vertices, m, p)
            return
        }
        if flags & 16 != 0 {
            polygonMesh(e, vertices, m, p)
            return
        }
        let closed = flags & 1 != 0
        // Spline-fitted polylines also list their frame points, which aren't drawn.
        let used = vertices.filter { flags & 4 == 0 || $0.int(70) & 16 == 0 }
        if flags & 8 != 0 {
            stroke(used.map { m.apply($0.point(10)) }, closed: closed, p)
            return
        }
        let elevation = e.double(30)
        let points = used.map { DXFVec($0.double(10), $0.double(20), elevation) }
        let bulges = used.map { $0.double(42) }
        let standard = max(e.double(40), e.double(41))
        let widths = used.map { max($0.double(40, standard), $0.double(41, standard)) }.filter { $0 > 0 }
        let width = widths.isEmpty ? 0 : widths.reduce(0, +) / Double(widths.count)
        let place = m * DXFMatrix.ocs(e.normal())
        stroke(Self.bulged(points, bulges, closed: closed).map { place.apply($0) }, closed: closed, p, width: width * place.lengthScale)
    }

    private mutating func polyface(_ vertices: [DXFEntity], _ m: DXFMatrix, _ p: Properties) {
        let corners = vertices.filter { $0.int(70) & 64 != 0 }.map { m.apply($0.point(10)) }
        for face in vertices where face.int(70) & 64 == 0 && face.int(70) & 128 != 0 {
            let indices = [71, 72, 73, 74].map { face.int($0) }.filter { $0 != 0 }
            guard indices.count >= 2 else { continue }
            let positions = indices.map { abs($0) - 1 }
            if positions.allSatisfy({ $0 < corners.count }) { self.face(positions.map { corners[$0] }, p) }
            for k in 0..<indices.count {
                // A negative index hides the edge that starts there.
                let from = indices[k], to = indices[(k + 1) % indices.count]
                guard from > 0 else { continue }
                let a = abs(from) - 1, b = abs(to) - 1
                guard a < corners.count, b < corners.count else { continue }
                stroke([corners[a], corners[b]], closed: false, p)
            }
        }
    }

    private mutating func polygonMesh(_ e: DXFEntity, _ vertices: [DXFEntity], _ m: DXFMatrix, _ p: Properties) {
        let rows = e.int(71), columns = e.int(72)
        let points = vertices.map { m.apply($0.point(10)) }
        guard rows > 0, columns > 0, rows <= 10_000, columns <= 10_000, points.count >= rows * columns else { return }
        let flags = e.int(70)
        for row in 0..<rows {
            stroke(Array(points[(row * columns)..<(row * columns + columns)]), closed: flags & 32 != 0, p)
        }
        for column in 0..<columns {
            stroke((0..<rows).map { points[$0 * columns + column] }, closed: flags & 1 != 0, p)
        }
        // The faces between the lines; a closed mesh also joins its last row or column to the first.
        let rowSpan = flags & 1 != 0 ? rows : rows - 1
        let columnSpan = flags & 32 != 0 ? columns : columns - 1
        for row in 0..<rowSpan {
            let next = (row + 1) % rows
            for column in 0..<columnSpan {
                let right = (column + 1) % columns
                face([points[row * columns + column], points[row * columns + right],
                      points[next * columns + right], points[next * columns + column]], p)
            }
        }
    }

    private mutating func spline(_ e: DXFEntity, _ m: DXFMatrix, _ p: Properties) {
        var control: [DXFVec] = []
        var fit: [DXFVec] = []
        for tag in e.tags {
            switch tag.code {
            case 10: control.append(DXFVec(tag.double, 0, 0))
            case 20: if !control.isEmpty { control[control.count - 1].y = tag.double }
            case 30: if !control.isEmpty { control[control.count - 1].z = tag.double }
            case 11: fit.append(DXFVec(tag.double, 0, 0))
            case 21: if !fit.isEmpty { fit[fit.count - 1].y = tag.double }
            case 31: if !fit.isEmpty { fit[fit.count - 1].z = tag.double }
            default: break
            }
        }
        let knots = e.tags.filter { $0.code == 40 }.map { $0.double }
        let weights = e.tags.filter { $0.code == 41 }.map { $0.double }
        let points: [DXFVec]
        if control.count >= 2 {
            points = Self.nurbs(control, e.int(71, 3), knots, weights)
        } else if fit.count >= 2 {
            points = Self.through(fit, closed: e.int(70) & 1 != 0)
        } else {
            return
        }
        stroke(points.map { m.apply($0) }, closed: false, p)
    }

    private mutating func text(_ e: DXFEntity, _ m: DXFMatrix, _ p: Properties) {
        if e.type == "ATTRIB" && e.int(70) & 1 != 0 { return }
        let content = DXFText.plain(e.string(1))
        guard !content.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let place = m * DXFMatrix.ocs(e.normal())
        let horizontal = e.int(72)
        // Attributes keep their vertical alignment in code 74; 73 is their field length.
        let vertical = e.type == "ATTRIB" ? e.int(74) : e.int(73)
        let first = e.point(10)
        let second = e.has(11) ? e.point(11) : first
        let fitted = horizontal == 3 || horizontal == 5
        var angle = e.double(50) * Double.pi / 180
        var fit = 0.0
        if fitted {
            let length = hypot(second.x - first.x, second.y - first.y)
            if length > 0 {
                angle = atan2(second.y - first.y, second.x - first.x)
                fit = length
            }
        }
        let anchor = (horizontal == 0 && vertical == 0) || fitted ? first : second
        var xAxis = DXFVec(cos(angle), sin(angle), 0)
        var yAxis = DXFVec(-sin(angle), cos(angle), 0)
        let generation = e.int(71)
        if generation & 2 != 0 { xAxis = xAxis * -1 }
        if generation & 4 != 0 { yAxis = yAxis * -1 }
        let factor = e.double(41, document.widthFactors[e.string(7, "STANDARD").uppercased()] ?? 1)
        addLabel(DXFLabel(text: content, origin: place.apply(anchor), xAxis: place.vector(xAxis), yAxis: place.vector(yAxis),
                          height: e.double(40, 1), widthFactor: factor > 0 ? factor : 1,
                          horizontal: horizontal == 4 ? 1 : (fitted ? 0 : min(max(horizontal, 0), 2)),
                          vertical: horizontal == 4 ? 2 : min(max(vertical, 0), 3),
                          wrap: 0, spacing: 1, fit: fit, stretch: horizontal == 3, ink: p.ink, layer: p.layer))
    }

    private mutating func mtext(_ e: DXFEntity, _ m: DXFMatrix, _ p: Properties) {
        let raw = e.tags.filter { $0.code == 3 }.map { $0.string }.joined() + e.string(1)
        let content = DXFText.plain(DXFText.plainMText(raw))
        guard !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let normal = e.normal().unit
        var xAxis = DXFVec(e.double(11), e.double(21), e.double(31))
        if xAxis.length == 0 {
            // Without a direction, code 50 is the rotation in radians.
            let angle = e.double(50)
            xAxis = DXFMatrix.ocs(normal).vector(DXFVec(cos(angle), sin(angle), 0))
        }
        xAxis = xAxis.unit
        let yAxis = normal.cross(xAxis).unit
        let attachment = min(max(e.int(71, 1), 1), 9)
        let verticals = [3, 2, 1]
        let spacing = e.double(44, 1)
        addLabel(DXFLabel(text: content, origin: m.apply(e.point(10)), xAxis: m.vector(xAxis), yAxis: m.vector(yAxis),
                          height: e.double(40, 1), widthFactor: 1, horizontal: (attachment - 1) % 3,
                          vertical: verticals[(attachment - 1) / 3], wrap: max(e.double(41), 0),
                          spacing: spacing > 0 ? spacing : 1, fit: 0, stretch: false, ink: p.ink, layer: p.layer))
    }

    private mutating func solid(_ e: DXFEntity, _ m: DXFMatrix, _ p: Properties) {
        let place = m * DXFMatrix.ocs(e.normal())
        let third = e.point(12)
        let fourth = e.has(13) ? e.point(13) : third
        // A solid's corners run 1, 2, 4, 3.
        var corners = [e.point(10), e.point(11), fourth, third]
        if fourth == third { corners.remove(at: 2) }
        fill([corners.map { place.apply($0) }], p)
    }

    private mutating func face(_ e: DXFEntity, _ m: DXFMatrix, _ p: Properties) {
        let third = e.point(12)
        let fourth = e.has(13) ? e.point(13) : third
        let corners = [e.point(10), e.point(11), third, fourth].map { m.apply($0) }
        face(corners, p)
        let hidden = e.int(70)
        for k in 0..<4 where hidden & (1 << k) == 0 {
            let a = corners[k], b = corners[(k + 1) % 4]
            if a != b { stroke([a, b], closed: false, p) }
        }
    }

    private mutating func mesh(_ e: DXFEntity, _ m: DXFMatrix, _ p: Properties) {
        let tags = e.tags
        guard let start = tags.firstIndex(where: { $0.code == 92 }) else { return }
        let count = tags[start].int
        var vertices: [DXFVec] = []
        var i = start + 1
        while vertices.count < count && i + 2 < tags.count && tags[i].code == 10 {
            vertices.append(m.apply(DXFVec(tags[i].double, tags[i + 1].double, tags[i + 2].double)))
            i += 3
        }
        guard i < tags.count, let listStart = tags[i...].firstIndex(where: { $0.code == 93 }) else { return }
        let size = tags[listStart].int
        let values = tags[(listStart + 1)...].prefix(max(size, 0)).filter { $0.code == 90 }.map { $0.int }
        var k = 0
        while k < values.count {
            let sides = values[k]
            guard sides > 0, k + sides < values.count else { break }
            for j in 0..<sides {
                let a = values[k + 1 + j], b = values[k + 1 + (j + 1) % sides]
                if a >= 0, b >= 0, a < vertices.count, b < vertices.count { stroke([vertices[a], vertices[b]], closed: false, p) }
            }
            let corners = (0..<sides).map { values[k + 1 + $0] }
            if corners.allSatisfy({ $0 >= 0 && $0 < vertices.count }) { face(corners.map { vertices[$0] }, p) }
            k += sides + 1
        }
    }

    private mutating func hatch(_ e: DXFEntity, _ m: DXFMatrix, _ p: Properties) {
        guard let start = e.tags.firstIndex(where: { $0.code == 91 }) else { return }
        let elevation = e.double(30)
        let place = m * DXFMatrix.ocs(e.normal())
        var cursor = Cursor(tags: e.tags, index: start)
        let count = cursor.int(91) ?? 0
        var rings: [[DXFVec]] = []
        for _ in 0..<min(max(count, 0), 10_000) {
            guard let flags = cursor.int(92) else { break }
            var ring: [DXFVec] = []
            if flags & 2 != 0 {
                let bulging = (cursor.int(72) ?? 0) != 0
                _ = cursor.int(73)
                let vertexCount = cursor.int(93) ?? 0
                var points: [DXFVec] = []
                var bulges: [Double] = []
                for _ in 0..<max(vertexCount, 0) {
                    guard let x = cursor.double(10), let y = cursor.double(20) else { break }
                    points.append(DXFVec(x, y, elevation))
                    bulges.append(bulging ? (cursor.double(42) ?? 0) : 0)
                }
                ring = Self.bulged(points, bulges, closed: true)
            } else {
                let edgeCount = cursor.int(93) ?? 0
                for _ in 0..<max(edgeCount, 0) {
                    guard let type = cursor.int(72) else { break }
                    for point in Self.edge(type, &cursor, elevation) where ring.last != point { ring.append(point) }
                }
            }
            // The objects the boundary was made from.
            while let code = cursor.code, code == 97 || code == 330 { cursor.index += 1 }
            if ring.count >= 2 { rings.append(ring.map { place.apply($0) }) }
        }
        // Solid and gradient hatches are filled; patterned ones show their outlines.
        if e.int(70) & 1 != 0 || e.int(450) != 0 {
            fill(rings, p)
        } else {
            for ring in rings { stroke(ring, closed: true, p) }
        }
    }

    private mutating func image(_ e: DXFEntity, _ m: DXFMatrix, _ p: Properties) {
        let columns = e.double(13), rows = e.double(23)
        guard columns > 0, rows > 0 else { return }
        let u = e.point(11), v = e.point(12)
        let base = e.point(10)
        // The insertion point is the middle of the first pixel.
        let corner = DXFVec(base.x - (u.x + v.x) / 2, base.y - (u.y + v.y) / 2, base.z - (u.z + v.z) / 2)
        let path = document.pictures[e.string(340).uppercased()] ?? ""
        let file = path.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last.map { String($0) } ?? ""
        let picture = DXFPicture(file: file, corner: m.apply(corner), u: m.vector(u * columns), v: m.vector(v * rows),
                                 layer: p.layer, ink: p.ink)
        let across = picture.corner + picture.u
        let up = picture.corner + picture.v
        scene.box.add(picture.corner)
        scene.box.add(across)
        scene.box.add(up)
        scene.box.add(across + picture.v)
        scene.pictures.append(picture)
    }

    private mutating func viewportFrame(_ e: DXFEntity, _ p: Properties) {
        guard let viewport = Self.viewport(e, document) else { return }
        let c = viewport.center, w = viewport.width / 2, h = viewport.height / 2
        stroke([DXFVec(c.x - w, c.y - h), DXFVec(c.x + w, c.y - h), DXFVec(c.x + w, c.y + h), DXFVec(c.x - w, c.y + h)],
               closed: true, p)
    }

    // Leaders and multilines: a run of points at one group code.
    private mutating func sequence(_ e: DXFEntity, _ m: DXFMatrix, _ p: Properties, code: Int, closed: Bool) {
        var points: [DXFVec] = []
        for tag in e.tags {
            if tag.code == code {
                points.append(DXFVec(tag.double, 0, 0))
            } else if tag.code == code + 10, !points.isEmpty {
                points[points.count - 1].y = tag.double
            } else if tag.code == code + 20, !points.isEmpty {
                points[points.count - 1].z = tag.double
            }
        }
        stroke(points.map { m.apply($0) }, closed: closed, p)
    }

    private mutating func insert(_ e: DXFEntity, _ m: DXFMatrix, _ p: Properties) {
        guard !p.frozen else { return }
        let inner = p.inherited
        // Attributes are placed in the drawing's own coordinates, not the block's.
        if p.visible { for child in e.children where child.type == "ATTRIB" { add(child, m, inner) } }
        let name = e.string(2).uppercased()
        guard let block = document.blocks[name], !chain.contains(name), chain.count < 16 else { return }
        let oriented = m * DXFMatrix.ocs(e.normal())
        let moved = oriented * DXFMatrix.translation(e.point(10))
        let place = moved * DXFMatrix.rotation(e.double(50) * Double.pi / 180)
        let sized = DXFMatrix.scaling(e.double(41, 1), e.double(42, 1), e.double(43, 1))
        let based = sized * DXFMatrix.translation(block.base * -1)
        let columns = min(max(e.int(70, 1), 1), 100), rows = min(max(e.int(71, 1), 1), 100)
        let across = e.double(44), down = e.double(45)
        chain.append(name)
        for row in 0..<rows {
            for column in 0..<columns {
                let shifted = place * DXFMatrix.translation(DXFVec(Double(column) * across, Double(row) * down, 0))
                add(block.entities, shifted * based, inner)
            }
        }
        chain.removeLast()
    }

    // A table's graphics are a block placed at the table's insertion point.
    private mutating func table(_ e: DXFEntity, _ m: DXFMatrix, _ p: Properties) {
        guard !p.frozen else { return }
        let name = e.string(2).uppercased()
        guard let block = document.blocks[name], !chain.contains(name), chain.count < 16 else { return }
        let moved = m * DXFMatrix.translation(e.point(10))
        chain.append(name)
        add(block.entities, moved * DXFMatrix.translation(block.base * -1), p.inherited)
        chain.removeLast()
    }

    // A dimension's lines, arrows and text are a block in the drawing's own coordinates.
    private mutating func dimension(_ e: DXFEntity, _ m: DXFMatrix, _ p: Properties) {
        guard !p.frozen else { return }
        let name = e.string(2).uppercased()
        guard let block = document.blocks[name], !chain.contains(name), chain.count < 16 else { return }
        let matrix = e.has(12) ? m * DXFMatrix.translation(e.point(12)) : m
        chain.append(name)
        add(block.entities, matrix, p.inherited)
        chain.removeLast()
    }

    static func viewport(_ e: DXFEntity, _ document: DXFDocument) -> DXFViewport? {
        // Viewport 1 is the sheet itself; status 0 is switched off.
        guard e.type == "VIEWPORT", e.int(69) != 1, e.int(68, 1) != 0 else { return nil }
        let width = e.double(40), height = e.double(41), viewHeight = e.double(45)
        guard width > 0, height > 0, viewHeight > 0 else { return nil }
        let hidden = Set(e.tags.filter { $0.code == 331 }.compactMap { document.layerNames[$0.string.uppercased()] })
        return DXFViewport(center: e.point(10), width: width, height: height, viewCenter: DXFVec(e.double(12), e.double(22)),
                           viewHeight: viewHeight, target: e.point(17), twist: e.double(51) * Double.pi / 180, hidden: hidden)
    }

    // MARK: Curves

    // Segments for a sweep: one every 2.5 degrees.
    static func steps(_ sweep: Double) -> Int {
        let count = abs(sweep) / (2.5 * Double.pi / 180)
        guard count.isFinite else { return 2 }
        return max(2, Int(min(count, 720).rounded(.up)))
    }

    static func arc(_ center: DXFVec, _ radius: Double, _ start: Double, _ end: Double) -> [DXFVec] {
        let count = steps(end - start)
        var points: [DXFVec] = []
        points.reserveCapacity(count + 1)
        for i in 0...count {
            let angle = start + (end - start) * Double(i) / Double(count)
            points.append(DXFVec(center.x + radius * cos(angle), center.y + radius * sin(angle), center.z))
        }
        return points
    }

    // A polyline with bulges: each bulge turns the segment after its vertex into an arc (tan of a quarter of its angle).
    static func bulged(_ points: [DXFVec], _ bulges: [Double], closed: Bool) -> [DXFVec] {
        guard points.count >= 2 else { return points }
        var result: [DXFVec] = [points[0]]
        let segments = closed ? points.count : points.count - 1
        for i in 0..<segments {
            let a = points[i], b = points[(i + 1) % points.count]
            let bulge = i < bulges.count ? bulges[i] : 0
            if abs(bulge) > 1e-9 {
                result.append(contentsOf: bulgeArc(a, b, bulge).dropFirst())
            } else {
                result.append(b)
            }
        }
        if closed && result.count > 2 { result.removeLast() }
        return result
    }

    static func bulgeArc(_ a: DXFVec, _ b: DXFVec, _ bulge: Double) -> [DXFVec] {
        let dx = b.x - a.x, dy = b.y - a.y
        let chord = (dx * dx + dy * dy).squareRoot()
        guard chord > 0 else { return [a, b] }
        let offset = chord / 2 * (1 - bulge * bulge) / (2 * bulge)
        let center = DXFVec((a.x + b.x) / 2 - dy / chord * offset, (a.y + b.y) / 2 + dx / chord * offset, a.z)
        let radius = hypot(a.x - center.x, a.y - center.y)
        let start = atan2(a.y - center.y, a.x - center.x)
        var points = arc(center, radius, start, start + 4 * atan(bulge))
        points[points.count - 1] = b
        return points
    }

    // Hatch boundary edges: 1 line, 2 arc, 3 elliptic arc, 4 spline.
    private static func edge(_ type: Int, _ c: inout Cursor, _ z: Double) -> [DXFVec] {
        switch type {
        case 1:
            let x1 = c.double(10) ?? 0, y1 = c.double(20) ?? 0
            let x2 = c.double(11) ?? 0, y2 = c.double(21) ?? 0
            return [DXFVec(x1, y1, z), DXFVec(x2, y2, z)]
        case 2:
            let x = c.double(10) ?? 0, y = c.double(20) ?? 0, radius = c.double(40) ?? 0
            let start = (c.double(50) ?? 0) * Double.pi / 180, end = (c.double(51) ?? 360) * Double.pi / 180
            let counterClockwise = (c.int(73) ?? 1) != 0
            guard radius > 0 else { return [] }
            let range = sweep(start, end, counterClockwise)
            return arc(DXFVec(x, y, z), radius, range.from, range.to)
        case 3:
            let x = c.double(10) ?? 0, y = c.double(20) ?? 0
            let mx = c.double(11) ?? 0, my = c.double(21) ?? 0
            let ratio = c.double(40) ?? 1
            let start = (c.double(50) ?? 0) * Double.pi / 180, end = (c.double(51) ?? 360) * Double.pi / 180
            let counterClockwise = (c.int(73) ?? 1) != 0
            // Hatch ellipses store angles; the curve needs its parameters.
            func parameter(_ angle: Double) -> Double { ratio > 0 ? atan2(sin(angle) / ratio, cos(angle)) : angle }
            let range = sweep(parameter(start), parameter(end), counterClockwise)
            let count = steps(range.to - range.from)
            return (0...count).map { i in
                let t = range.from + (range.to - range.from) * Double(i) / Double(count)
                let ct = cos(t), st = sin(t)
                return DXFVec(x + mx * ct - my * ratio * st, y + my * ct + mx * ratio * st, z)
            }
        case 4:
            let degree = c.int(94) ?? 3
            let rational = (c.int(73) ?? 0) != 0
            _ = c.int(74)
            let knotCount = c.int(95) ?? 0, controlCount = c.int(96) ?? 0
            var knots: [Double] = []
            var control: [DXFVec] = []
            var weights: [Double] = []
            for _ in 0..<max(knotCount, 0) {
                guard let knot = c.double(40) else { break }
                knots.append(knot)
            }
            for _ in 0..<max(controlCount, 0) {
                guard let x = c.double(10), let y = c.double(20) else { break }
                control.append(DXFVec(x, y, z))
                if rational { weights.append(c.double(42) ?? 1) }
            }
            // Newer files add fit points after a count; a 97 followed by anything else belongs to the boundary.
            var fit: [DXFVec] = []
            if c.code == 97 {
                let next = c.index + 1 < c.tags.count ? c.tags[c.index + 1].code : -1
                if next == 11 || next == 12 || next == 13 || next == 72 {
                    let fitCount = c.int(97) ?? 0
                    for _ in 0..<max(fitCount, 0) {
                        guard let x = c.double(11), let y = c.double(21) else { break }
                        fit.append(DXFVec(x, y, z))
                    }
                }
            }
            _ = c.double(12)
            _ = c.double(22)
            _ = c.double(13)
            _ = c.double(23)
            if control.count >= 2 { return nurbs(control, degree, knots, weights) }
            if fit.count >= 2 { return through(fit, closed: false) }
            return []
        default:
            return []
        }
    }

    // A counter-clockwise sweep from start to end; a clockwise hatch edge stores its angles mirrored.
    private static func sweep(_ start: Double, _ end: Double, _ counterClockwise: Bool) -> (from: Double, to: Double) {
        if counterClockwise { return (start, after(start, end)) }
        // Clockwise: from the mirrored start down to the mirrored end.
        let from = -start
        return (from, 2 * from - after(from, 2 * from + end))
    }

    // The end angle of a counter-clockwise sweep from start: more than start, by at most a full turn.
    static func after(_ start: Double, _ end: Double) -> Double {
        guard start.isFinite, end.isFinite else { return start.isFinite ? start + 2 * Double.pi : 2 * Double.pi }
        var delta = (end - start).truncatingRemainder(dividingBy: 2 * Double.pi)
        if delta <= 0 { delta += 2 * Double.pi }
        return start + delta
    }

    // A NURBS curve sampled along its knots (de Boor's algorithm).
    static func nurbs(_ points: [DXFVec], _ requested: Int, _ givenKnots: [Double], _ givenWeights: [Double]) -> [DXFVec] {
        let n = points.count
        let p = min(max(requested, 1), n - 1)
        guard p >= 1 else { return points }
        var knots = givenKnots
        var ordered = knots.count == n + p + 1
        if ordered {
            for i in 1..<knots.count where knots[i] < knots[i - 1] { ordered = false }
        }
        if !ordered {
            // A clamped, evenly spaced knot vector when the file's is missing or broken.
            knots = Array(repeating: 0, count: p + 1)
            let inner = n - p - 1
            if inner > 0 { for i in 1...inner { knots.append(Double(i) / Double(inner + 1)) } }
            knots += Array(repeating: 1, count: p + 1)
        }
        let weights = givenWeights.count == n && givenWeights.allSatisfy({ $0 > 0 }) ? givenWeights : Array(repeating: 1, count: n)
        let start = knots[p], end = knots[n]
        guard end > start else { return points }
        let samples = min(4000, max(16, n * 10))
        var result: [DXFVec] = []
        result.reserveCapacity(samples + 1)
        for s in 0...samples {
            let t = start + (end - start) * Double(s) / Double(samples)
            result.append(deBoor(t, p, knots, points, weights))
        }
        return result
    }

    private static func deBoor(_ t: Double, _ p: Int, _ knots: [Double], _ points: [DXFVec], _ weights: [Double]) -> DXFVec {
        let n = points.count
        var k: Int
        if t >= knots[n] {
            k = n - 1
            while k > p && knots[k] >= knots[n] { k -= 1 }
        } else {
            var low = p, high = n
            while high - low > 1 {
                let middle = (low + high) / 2
                if knots[middle] <= t { low = middle } else { high = middle }
            }
            k = low
        }
        var x: [Double] = [], y: [Double] = [], z: [Double] = [], w: [Double] = []
        for j in 0...p {
            let i = j + k - p
            let weight = weights[i]
            x.append(points[i].x * weight)
            y.append(points[i].y * weight)
            z.append(points[i].z * weight)
            w.append(weight)
        }
        for r in 1...p {
            for j in stride(from: p, through: r, by: -1) {
                let low = knots[j + k - p], high = knots[j + 1 + k - r]
                let alpha = high > low ? (t - low) / (high - low) : 0
                x[j] = x[j - 1] * (1 - alpha) + x[j] * alpha
                y[j] = y[j - 1] * (1 - alpha) + y[j] * alpha
                z[j] = z[j - 1] * (1 - alpha) + z[j] * alpha
                w[j] = w[j - 1] * (1 - alpha) + w[j] * alpha
            }
        }
        let weight = w[p] != 0 ? w[p] : 1
        return DXFVec(x[p] / weight, y[p] / weight, z[p] / weight)
    }

    // A smooth curve through fit points (Catmull-Rom).
    static func through(_ fit: [DXFVec], closed: Bool) -> [DXFVec] {
        let count = fit.count
        guard count > 2 else { return fit }
        var result: [DXFVec] = [fit[0]]
        let segments = closed ? count : count - 1
        for i in 0..<segments {
            let p0 = fit[closed ? (i - 1 + count) % count : max(i - 1, 0)]
            let p1 = fit[i % count]
            let p2 = fit[(i + 1) % count]
            let p3 = fit[closed ? (i + 2) % count : min(i + 2, count - 1)]
            for s in 1...8 {
                let t = Double(s) / 8
                result.append(DXFVec(catmull(p0.x, p1.x, p2.x, p3.x, t), catmull(p0.y, p1.y, p2.y, p3.y, t),
                                     catmull(p0.z, p1.z, p2.z, p3.z, t)))
            }
        }
        return result
    }

    private static func catmull(_ a: Double, _ b: Double, _ c: Double, _ d: Double, _ t: Double) -> Double {
        let t2 = t * t, t3 = t2 * t
        let first = 2 * b
        let second = (c - a) * t
        let third = (2 * a - 5 * b + 4 * c - d) * t2
        let fourth = (3 * b - a - 3 * c + d) * t3
        return 0.5 * (first + second + third + fourth)
    }
}

// Text as plain characters: AutoCAD's control codes and multi-line formatting removed.
enum DXFText {
    // %%c Ø, %%d °, %%p ±, %%% %, %%nnn a character code; underline and overline switches are dropped.
    static func plain(_ raw: String) -> String {
        let chars = Array(unicode(raw))
        var result = ""
        var i = 0
        while i < chars.count {
            if chars[i] == "%", i + 2 < chars.count, chars[i + 1] == "%" {
                let code = chars[i + 2].lowercased()
                switch code {
                case "c": result.append("Ø"); i += 3; continue
                case "d": result.append("°"); i += 3; continue
                case "p": result.append("±"); i += 3; continue
                case "%": result.append("%"); i += 3; continue
                case "u", "o", "k": i += 3; continue
                default:
                    var digits = ""
                    var j = i + 2
                    while j < chars.count && digits.count < 3 && chars[j].isASCII && chars[j].isNumber {
                        digits.append(chars[j])
                        j += 1
                    }
                    if let value = Int(digits), let scalar = Unicode.Scalar(value) {
                        result.append(Character(scalar))
                        i = j
                        continue
                    }
                }
            }
            result.append(chars[i])
            i += 1
        }
        return result
    }

    // \U+00B0 style escapes from older files.
    static func unicode(_ raw: String) -> String {
        guard raw.contains("\\U+") || raw.contains("\\u+") else { return raw }
        let chars = Array(raw)
        var result = ""
        var i = 0
        while i < chars.count {
            if chars[i] == "\\", i + 6 < chars.count, chars[i + 1] == "U" || chars[i + 1] == "u", chars[i + 2] == "+",
               let value = UInt32(String(chars[(i + 3)...(i + 6)]), radix: 16), let scalar = Unicode.Scalar(value) {
                result.append(Character(scalar))
                i += 7
                continue
            }
            result.append(chars[i])
            i += 1
        }
        return result
    }

    // Multi-line text: \P is a new line, \S stacks a fraction, and font, size, color and other codes are removed.
    static func plainMText(_ raw: String) -> String {
        let chars = Array(unicode(raw))
        var result = ""
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c == "{" || c == "}" {
                i += 1
                continue
            }
            guard c == "\\", i + 1 < chars.count else {
                result.append(c)
                i += 1
                continue
            }
            let code = chars[i + 1]
            switch code {
            case "P", "X":
                result.append("\n")
                i += 2
            case "~":
                result.append(" ")
                i += 2
            case "\\", "{", "}":
                result.append(code)
                i += 2
            case "L", "l", "O", "o", "K", "k", "N":
                i += 2
            case "S":
                var j = i + 2
                var stack = ""
                while j < chars.count && chars[j] != ";" {
                    stack.append(chars[j] == "^" || chars[j] == "#" ? "/" : chars[j])
                    j += 1
                }
                if stack.hasPrefix("/") { stack.removeFirst() }
                if stack.hasSuffix("/") { stack.removeLast() }
                result.append(stack)
                i = j + 1
            case "f", "F", "H", "W", "Q", "T", "A", "C", "c", "p":
                var j = i + 2
                while j < chars.count && chars[j] != ";" { j += 1 }
                i = j + 1
            default:
                result.append(code)
                i += 2
            }
        }
        return result.replacingOccurrences(of: "^I", with: "    ").replacingOccurrences(of: "^J", with: "\n")
    }
}
