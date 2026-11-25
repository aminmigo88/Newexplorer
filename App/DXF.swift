import Foundation

// DXF drawings, AutoCAD's exchange format: reading text and binary files of every version into
// layers, line types, blocks, entities and layouts. DXFScene.swift turns them into lines, fills and text.

// A point or direction in a drawing.
struct DXFVec: Hashable {
    var x: Double
    var y: Double
    var z: Double

    init(_ x: Double = 0, _ y: Double = 0, _ z: Double = 0) {
        self.x = x
        self.y = y
        self.z = z
    }
    static func + (a: DXFVec, b: DXFVec) -> DXFVec { DXFVec(a.x + b.x, a.y + b.y, a.z + b.z) }
    static func - (a: DXFVec, b: DXFVec) -> DXFVec { DXFVec(a.x - b.x, a.y - b.y, a.z - b.z) }
    static func * (a: DXFVec, s: Double) -> DXFVec { DXFVec(a.x * s, a.y * s, a.z * s) }
    func dot(_ b: DXFVec) -> Double { x * b.x + y * b.y + z * b.z }
    func cross(_ b: DXFVec) -> DXFVec { DXFVec(y * b.z - z * b.y, z * b.x - x * b.z, x * b.y - y * b.x) }
    var length: Double { (x * x + y * y + z * z).squareRoot() }
    var unit: DXFVec {
        let size = length
        return size > 0 ? self * (1 / size) : self
    }
}

// Places points: the axes the unit vectors go to, then a shift.
struct DXFMatrix {
    var ax: DXFVec
    var ay: DXFVec
    var az: DXFVec
    var t: DXFVec

    init(ax: DXFVec = DXFVec(1, 0, 0), ay: DXFVec = DXFVec(0, 1, 0), az: DXFVec = DXFVec(0, 0, 1), t: DXFVec = DXFVec()) {
        self.ax = ax
        self.ay = ay
        self.az = az
        self.t = t
    }
    static let identity = DXFMatrix()

    func apply(_ p: DXFVec) -> DXFVec {
        DXFVec(ax.x * p.x + ay.x * p.y + az.x * p.z + t.x,
               ax.y * p.x + ay.y * p.y + az.y * p.z + t.y,
               ax.z * p.x + ay.z * p.y + az.z * p.z + t.z)
    }
    func vector(_ v: DXFVec) -> DXFVec {
        DXFVec(ax.x * v.x + ay.x * v.y + az.x * v.z,
               ax.y * v.x + ay.y * v.y + az.y * v.z,
               ax.z * v.x + ay.z * v.y + az.z * v.z)
    }
    // a * b places with b first, then a.
    static func * (a: DXFMatrix, b: DXFMatrix) -> DXFMatrix {
        DXFMatrix(ax: a.vector(b.ax), ay: a.vector(b.ay), az: a.vector(b.az), t: a.apply(b.t))
    }
    static func translation(_ v: DXFVec) -> DXFMatrix { DXFMatrix(t: v) }
    static func scaling(_ x: Double, _ y: Double, _ z: Double) -> DXFMatrix {
        DXFMatrix(ax: DXFVec(x, 0, 0), ay: DXFVec(0, y, 0), az: DXFVec(0, 0, z))
    }
    static func rotation(_ angle: Double) -> DXFMatrix {
        DXFMatrix(ax: DXFVec(cos(angle), sin(angle), 0), ay: DXFVec(-sin(angle), cos(angle), 0))
    }
    // The object coordinate system of a flat entity, from its extrusion direction (AutoCAD's arbitrary axis algorithm).
    static func ocs(_ normal: DXFVec) -> DXFMatrix {
        let n = normal.unit
        if n.length == 0 || (abs(n.x) < 1e-12 && abs(n.y) < 1e-12 && n.z > 0) { return .identity }
        let limit = 1.0 / 64.0
        let axis = abs(n.x) < limit && abs(n.y) < limit ? DXFVec(0, 1, 0) : DXFVec(0, 0, 1)
        let ax = axis.cross(n).unit
        let ay = n.cross(ax).unit
        return DXFMatrix(ax: ax, ay: ay, az: n)
    }
    // How much lengths in the XY plane grow, for dashes and line widths.
    var lengthScale: Double { ax.cross(ay).length.squareRoot() }
}

// A color: the drawing's foreground (AutoCAD color 7, black on white and white on black) or a fixed color.
enum DXFInk: Hashable {
    case foreground
    case rgb(UInt8, UInt8, UInt8)

    static func trueColor(_ value: Int) -> DXFInk {
        .rgb(UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF))
    }
    // The AutoCAD Color Index: 1–9 named colors, 10–249 shades of 24 hues, 250–255 grays.
    static func aci(_ index: Int) -> DXFInk {
        switch index {
        case 1: return .rgb(255, 0, 0)
        case 2: return .rgb(255, 255, 0)
        case 3: return .rgb(0, 255, 0)
        case 4: return .rgb(0, 255, 255)
        case 5: return .rgb(0, 0, 255)
        case 6: return .rgb(255, 0, 255)
        case 8: return .rgb(128, 128, 128)
        case 9: return .rgb(192, 192, 192)
        case 10...249:
            let hue = Double((index - 10) / 10) * 15
            let variant = (index - 10) % 10
            let levels: [Double] = [255, 165, 127, 76, 38]
            let level = levels[variant / 2]
            let pale = variant % 2 == 1
            let full = hueColor(hue)
            func shade(_ part: Double) -> UInt8 {
                let base = pale ? part + floor((255 - part) / 2) : part
                return UInt8(max(0, min(255, (base * level / 255).rounded())))
            }
            return .rgb(shade(full.0), shade(full.1), shade(full.2))
        case 250...255:
            let grays: [UInt8] = [51, 80, 105, 130, 190, 255]
            let gray = grays[index - 250]
            return .rgb(gray, gray, gray)
        default:
            return .foreground
        }
    }
    private static func hueColor(_ hue: Double) -> (Double, Double, Double) {
        let h = hue.truncatingRemainder(dividingBy: 360) / 60
        let sector = Int(h)
        let f = h - Double(sector)
        let up = floor(255 * f)
        let down = floor(255 * (1 - f))
        switch sector {
        case 0: return (255, up, 0)
        case 1: return (down, 255, 0)
        case 2: return (0, 255, up)
        case 3: return (0, down, 255)
        case 4: return (up, 0, 255)
        default: return (255, 0, down)
        }
    }
}

enum DXFValue {
    case text(String)
    case number(Double)
    case integer(Int)
}

// One group code and its value.
struct DXFTag {
    let code: Int
    let value: DXFValue

    var double: Double {
        switch value {
        case let .number(number): return number
        case let .integer(integer): return Double(integer)
        case let .text(text): return Double(text.trimmingCharacters(in: .whitespaces)) ?? 0
        }
    }
    var int: Int {
        switch value {
        case let .integer(integer): return integer
        case let .number(number): return number.isFinite && abs(number) < 1e15 ? Int(number) : 0
        case let .text(text): return Int(text.trimmingCharacters(in: .whitespaces)) ?? 0
        }
    }
    var string: String {
        switch value {
        case let .text(text): return text
        case let .number(number): return String(number)
        case let .integer(integer): return String(integer)
        }
    }
}

enum DXFReader {
    enum Kind {
        case text
        case number
        case integer
        case binary
    }
    // The type of value each group code holds, as the DXF reference defines it.
    static func kind(_ code: Int) -> Kind {
        switch code {
        case 10...59, 110...149, 210...239, 460...469, 1010...1059: return .number
        case 60...79, 90...99, 160...179, 270...299, 370...389, 400...409, 420...429, 440...459, 1060...1071: return .integer
        case 310...319, 1004: return .binary
        default: return .text
        }
    }
    // Bytes of an integer value in a binary DXF.
    static func integerSize(_ code: Int) -> Int {
        switch code {
        case 290...299: return 1
        case 90...99, 420...429, 440...459, 1071: return 4
        case 160...169: return 8
        default: return 2
        }
    }
    static let binarySentinel: [UInt8] = Array("AutoCAD Binary DXF\r\n".utf8) + [0x1A, 0x00]

    static func tags(from data: Data) throws -> [DXFTag] {
        let bytes = [UInt8](data)
        if bytes.count >= binarySentinel.count && bytes.starts(with: binarySentinel) { return try binaryTags(bytes) }
        var text = bytes
        // A 0 after the last byte stops every number read at the end of the file.
        text.append(0)
        return try textTags(text)
    }

    private static func textTags(_ bytes: [UInt8]) throws -> [DXFTag] {
        var tags: [DXFTag] = []
        tags.reserveCapacity(bytes.count / 16)
        var broken = false
        bytes.withUnsafeBufferPointer { buffer in
            guard let base = buffer.baseAddress else { return }
            let end = buffer.count - 1
            var position = 0
            // Skips a UTF-8 byte order mark.
            if end >= 3 && base[0] == 0xEF && base[1] == 0xBB && base[2] == 0xBF { position = 3 }
            while position < end {
                let codeStart = position
                while position < end && base[position] != 10 { position += 1 }
                let codeEnd = position
                position += 1
                guard let code = integer(base, codeStart, codeEnd) else {
                    if blank(base, codeStart, codeEnd) { continue }
                    broken = true
                    return
                }
                let valueStart = position
                while position < end && base[position] != 10 { position += 1 }
                var valueEnd = position
                position += 1
                while valueEnd > valueStart && base[valueEnd - 1] == 13 { valueEnd -= 1 }
                switch kind(code) {
                case .number:
                    tags.append(DXFTag(code: code, value: .number(number(base, valueStart, valueEnd))))
                case .integer:
                    var value = 0
                    if let whole = integer(base, valueStart, valueEnd) {
                        value = whole
                    } else {
                        let parsed = number(base, valueStart, valueEnd)
                        if parsed.isFinite && abs(parsed) < 1e15 { value = Int(parsed) }
                    }
                    tags.append(DXFTag(code: code, value: .integer(value)))
                case .binary:
                    tags.append(DXFTag(code: code, value: .text("")))
                case .text:
                    let value = text(UnsafeBufferPointer(start: base + valueStart, count: valueEnd - valueStart))
                    tags.append(DXFTag(code: code, value: .text(value)))
                    if code == 0 && value.trimmingCharacters(in: .whitespaces) == "EOF" { return }
                }
            }
        }
        if broken { throw ExplorerError("This DXF file is damaged, or it’s another kind of file.") }
        return tags
    }

    private static func binaryTags(_ bytes: [UInt8]) throws -> [DXFTag] {
        let count = bytes.count
        var index = binarySentinel.count
        // Release 12 files use 1-byte group codes; later ones use 2 bytes.
        let shortCodes = count > index + 1 && bytes[index] == 0 && bytes[index + 1] != 0
        var tags: [DXFTag] = []
        tags.reserveCapacity(count / 10)
        let cutShort = ExplorerError("This binary DXF file is cut short.")
        while index < count {
            var code: Int
            if shortCodes {
                code = Int(bytes[index])
                index += 1
                if code == 255 {
                    guard index + 2 <= count else { throw cutShort }
                    code = Int(bytes[index]) | Int(bytes[index + 1]) << 8
                    index += 2
                }
            } else {
                guard index + 2 <= count else { throw cutShort }
                code = Int(bytes[index]) | Int(bytes[index + 1]) << 8
                index += 2
            }
            switch kind(code) {
            case .binary:
                guard index < count else { throw cutShort }
                let length = Int(bytes[index])
                index += 1 + length
                guard index <= count else { throw cutShort }
                tags.append(DXFTag(code: code, value: .text("")))
            case .number:
                guard index + 8 <= count else { throw cutShort }
                var raw: UInt64 = 0
                for k in 0..<8 { raw |= UInt64(bytes[index + k]) << (8 * UInt64(k)) }
                index += 8
                tags.append(DXFTag(code: code, value: .number(Double(bitPattern: raw))))
            case .integer:
                let size = integerSize(code)
                guard index + size <= count else { throw cutShort }
                var raw: UInt64 = 0
                for k in 0..<size { raw |= UInt64(bytes[index + k]) << (8 * UInt64(k)) }
                index += size
                let value: Int
                switch size {
                case 1: value = Int(Int8(bitPattern: UInt8(truncatingIfNeeded: raw)))
                case 2: value = Int(Int16(bitPattern: UInt16(truncatingIfNeeded: raw)))
                case 4: value = Int(Int32(bitPattern: UInt32(truncatingIfNeeded: raw)))
                default: value = Int(Int64(bitPattern: raw))
                }
                tags.append(DXFTag(code: code, value: .integer(value)))
            case .text:
                var end = index
                while end < count && bytes[end] != 0 { end += 1 }
                let value = bytes[index..<end].withUnsafeBufferPointer { text($0) }
                index = end + 1
                tags.append(DXFTag(code: code, value: .text(value)))
                if code == 0 && value == "EOF" { return tags }
            }
        }
        return tags
    }

    private static func blank(_ base: UnsafePointer<UInt8>, _ start: Int, _ end: Int) -> Bool {
        var i = start
        while i < end {
            if base[i] != 32 && base[i] != 9 && base[i] != 13 { return false }
            i += 1
        }
        return true
    }
    // A whole-line integer, or nil when the line holds something else.
    private static func integer(_ base: UnsafePointer<UInt8>, _ start: Int, _ end: Int) -> Int? {
        var i = start
        while i < end && (base[i] == 32 || base[i] == 9) { i += 1 }
        var negative = false
        if i < end && (base[i] == 45 || base[i] == 43) {
            negative = base[i] == 45
            i += 1
        }
        var value = 0
        var digits = 0
        while i < end && base[i] >= 48 && base[i] <= 57 {
            value = value * 10 + Int(base[i] - 48)
            digits += 1
            if digits > 17 { return nil }
            i += 1
        }
        while i < end && (base[i] == 32 || base[i] == 9 || base[i] == 13) { i += 1 }
        guard digits > 0, i == end else { return nil }
        return negative ? -value : value
    }
    private static func number(_ base: UnsafePointer<UInt8>, _ start: Int, _ end: Int) -> Double {
        var i = start
        while i < end && (base[i] == 32 || base[i] == 9) { i += 1 }
        // An empty line is 0; reading on would take the next line's number.
        guard i < end else { return 0 }
        let pointer = UnsafeRawPointer(base + i).assumingMemoryBound(to: CChar.self)
        return strtod(pointer, nil)
    }
    // Text is UTF-8 in files from AutoCAD 2007 on, and Windows code page 1252 in most older ones.
    private static func text(_ bytes: UnsafeBufferPointer<UInt8>) -> String {
        if let utf8 = String(bytes: bytes, encoding: .utf8) { return utf8 }
        return String(bytes: bytes, encoding: .windowsCP1252) ?? ""
    }
}

// An entity or table entry: its type, its tags, and the vertices or attributes that follow it.
struct DXFEntity {
    let type: String
    let tags: [DXFTag]
    var children: [DXFEntity] = []

    func tag(_ code: Int) -> DXFTag? { tags.first(where: { $0.code == code }) }
    func has(_ code: Int) -> Bool { tags.contains(where: { $0.code == code }) }
    func double(_ code: Int, _ fallback: Double = 0) -> Double { tag(code)?.double ?? fallback }
    func int(_ code: Int, _ fallback: Int = 0) -> Int { tag(code)?.int ?? fallback }
    func string(_ code: Int, _ fallback: String = "") -> String { tag(code)?.string ?? fallback }
    // The point at a code: X there, Y at code + 10 and Z at code + 20.
    func point(_ code: Int) -> DXFVec { DXFVec(double(code), double(code + 10), double(code + 20)) }
    // The extrusion direction of a flat entity; up when the file gives none.
    func normal() -> DXFVec {
        has(210) ? DXFVec(double(210), double(220), double(230, 1)) : DXFVec(0, 0, 1)
    }
}

struct DXFLayer {
    var ink = DXFInk.foreground
    var off = false
    var frozen = false
    var lineType = "CONTINUOUS"
    var weight = -3
}

struct DXFBlock {
    let base: DXFVec
    let entities: [DXFEntity]
}

// A layout: a print sheet with its own entities and windows (viewports) onto the main drawing.
struct DXFLayoutSource {
    let name: String
    let entities: [DXFEntity]
    let low: DXFVec?
    let high: DXFVec?
}

// Everything read from a file. Names of layers, line types, styles and blocks are upper case, as AutoCAD compares them.
final class DXFDocument {
    var units = 0
    var lineTypeScale = 1.0
    var layers: [String: DXFLayer] = [:]
    var layerNames: [String: String] = [:]
    var lineTypes: [String: [Double]] = [:]
    var widthFactors: [String: Double] = [:]
    var blocks: [String: DXFBlock] = [:]
    var model: [DXFEntity] = []
    var paper: [DXFEntity] = []
    var layouts: [DXFLayoutSource] = []
    var pictures: [String: String] = [:]
    private var blockRecords: [String: String] = [:]
    private var layoutRecords: [(name: String, order: Int, block: String, low: DXFVec, high: DXFVec)] = []

    init(_ tags: [DXFTag]) {
        var index = 0
        while index < tags.count {
            guard tags[index].code == 0, Self.word(tags[index]) == "SECTION" else {
                index += 1
                continue
            }
            let name = index + 1 < tags.count && tags[index + 1].code == 2 ? Self.word(tags[index + 1]) : ""
            var end = index + 1
            while end < tags.count && !(tags[end].code == 0 && Self.word(tags[end]) == "ENDSEC") { end += 1 }
            let body = min(index + 2, end)..<end
            switch name {
            case "HEADER": readHeader(tags, body)
            case "TABLES": readTables(Self.records(tags, body))
            case "BLOCKS": readBlocks(Self.records(tags, body))
            case "ENTITIES":
                for entity in Self.records(tags, body) {
                    if entity.int(67) == 1 { paper.append(entity) } else { model.append(entity) }
                }
            case "OBJECTS": readObjects(Self.records(tags, body))
            default: break
            }
            index = end + 1
        }
        // Some programs keep the drawing in the model space block instead of the entities section.
        if model.isEmpty, let block = blocks["*MODEL_SPACE"] { model = block.entities }
        if paper.isEmpty, let block = blocks["*PAPER_SPACE"] { paper = block.entities }
        for record in layoutRecords.sorted(by: { $0.order < $1.order }) where record.name.uppercased() != "MODEL" {
            let block = (blockRecords[record.block] ?? "").uppercased()
            let entities = block == "*PAPER_SPACE" ? paper : (blocks[block]?.entities ?? [])
            guard !entities.isEmpty else { continue }
            let valid = record.high.x > record.low.x && record.high.y > record.low.y && abs(record.high.x) < 1e19
            layouts.append(DXFLayoutSource(name: record.name, entities: entities,
                                           low: valid ? record.low : nil, high: valid ? record.high : nil))
        }
        // Files before AutoCAD 2000 have one sheet and no layout objects.
        if layouts.isEmpty && !paper.isEmpty {
            layouts.append(DXFLayoutSource(name: "Layout", entities: paper, low: nil, high: nil))
        }
    }

    // True when the main drawing holds 3D solids, which can't be shown.
    var hasSolids: Bool {
        model.contains { ["3DSOLID", "BODY", "REGION", "SURFACE", "EXTRUDEDSURFACE", "REVOLVEDSURFACE"].contains($0.type) }
    }

    private static func word(_ tag: DXFTag) -> String {
        tag.string.trimmingCharacters(in: .whitespaces).uppercased()
    }

    // Splits tags into records at each group code 0; vertices and attributes join the entity before them.
    static func records(_ tags: [DXFTag], _ range: Range<Int>) -> [DXFEntity] {
        var result: [DXFEntity] = []
        var index = range.lowerBound
        while index < range.upperBound {
            guard tags[index].code == 0 else {
                index += 1
                continue
            }
            let type = word(tags[index])
            var next = index + 1
            while next < range.upperBound && tags[next].code != 0 { next += 1 }
            let entity = DXFEntity(type: type, tags: Array(tags[(index + 1)..<next]))
            switch type {
            case "VERTEX", "ATTRIB":
                if !result.isEmpty { result[result.count - 1].children.append(entity) }
            case "SEQEND":
                break
            default:
                result.append(entity)
            }
            index = next
        }
        return result
    }

    private func readHeader(_ tags: [DXFTag], _ range: Range<Int>) {
        var index = range.lowerBound
        while index + 1 < range.upperBound {
            if tags[index].code == 9 {
                let value = tags[index + 1]
                switch Self.word(tags[index]) {
                case "$INSUNITS": units = value.int
                case "$LTSCALE": if value.double > 0 { lineTypeScale = value.double }
                default: break
                }
            }
            index += 1
        }
    }

    private func readTables(_ records: [DXFEntity]) {
        for record in records {
            switch record.type {
            case "LAYER":
                let name = record.string(2).uppercased()
                let color = record.int(62, 7)
                var layer = DXFLayer()
                layer.off = color < 0
                layer.frozen = record.int(70) & 1 != 0
                if let trueColor = record.tag(420) { layer.ink = .trueColor(trueColor.int) } else { layer.ink = .aci(abs(color)) }
                layer.lineType = record.string(6, "CONTINUOUS").uppercased()
                layer.weight = record.int(370, -3)
                layers[name] = layer
                if let handle = record.tag(5) { layerNames[handle.string.uppercased()] = name }
            case "LTYPE":
                // Line types with text or shapes in them stay solid.
                let complex = record.tags.contains { $0.code == 74 && $0.int != 0 }
                lineTypes[record.string(2).uppercased()] = complex ? [] : record.tags.filter { $0.code == 49 }.map { $0.double }
            case "STYLE":
                let factor = record.double(41, 1)
                widthFactors[record.string(2).uppercased()] = factor > 0 ? factor : 1
            case "BLOCK_RECORD":
                if let handle = record.tag(5) { blockRecords[handle.string.uppercased()] = record.string(2) }
            default:
                break
            }
        }
    }

    private func readBlocks(_ records: [DXFEntity]) {
        var current: (name: String, base: DXFVec, external: Bool)?
        var entities: [DXFEntity] = []
        for record in records {
            switch record.type {
            case "BLOCK":
                // An external reference points to another file, which isn't available here.
                current = (name: record.string(2), base: record.point(10), external: record.int(70) & 4 != 0)
                entities = []
            case "ENDBLK":
                if let block = current {
                    blocks[block.name.uppercased()] = DXFBlock(base: block.base, entities: block.external ? [] : entities)
                }
                current = nil
                entities = []
            default:
                entities.append(record)
            }
        }
    }

    private func readObjects(_ records: [DXFEntity]) {
        for record in records {
            switch record.type {
            case "LAYOUT":
                var inLayout = false
                var name = "", order = 0, block = ""
                var low = DXFVec(), high = DXFVec()
                for tag in record.tags {
                    if tag.code == 100 {
                        inLayout = tag.string.trimmingCharacters(in: .whitespaces) == "AcDbLayout"
                        continue
                    }
                    guard inLayout else { continue }
                    switch tag.code {
                    case 1: name = tag.string
                    case 71: order = tag.int
                    case 10: low.x = tag.double
                    case 20: low.y = tag.double
                    case 11: high.x = tag.double
                    case 21: high.y = tag.double
                    case 330: block = tag.string.uppercased()
                    default: break
                    }
                }
                layoutRecords.append((name: name, order: order, block: block, low: low, high: high))
            case "IMAGEDEF":
                if let handle = record.tag(5) { pictures[handle.string.uppercased()] = record.string(1) }
            default:
                break
            }
        }
    }
}
