import UIKit
import SceneKit
import SceneKit.ModelIO
import ModelIO

// What the 3D view shows: a model read by Newexplorer (STL, 3MF, STEP, IGES, DXF), or a scene from Apple's Model I/O (OBJ).
enum Model3DContent {
    case mesh(Model3D)
    case scene(SCNScene)
}

enum Model3DFile {
    static func handles(_ name: String) -> Bool {
        ["stl", "obj", "3mf", "step", "stp", "iges", "igs"].contains((name as NSString).pathExtension.lowercased())
    }

    static func load(_ url: URL) throws -> Model3DContent {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        if size > 500_000_000 { throw ExplorerError("This 3D file is too big to show (over 500 MB).") }
        var model = Model3D()
        switch url.pathExtension.lowercased() {
        case "stl":
            let data = try Data(contentsOf: url, options: .mappedIfSafe)
            let positions = try STLReader.read(data)
            model.surfaces = [Model3D.Surface(positions: positions, ink: nil)]
        case "3mf":
            model.surfaces = try ThreeMFReader.read(url)
        case "step", "stp", "iges", "igs":
            // Reading a CAD file takes several times its size in memory.
            if size > 200_000_000 { throw ExplorerError("This CAD file is too big to show (over 200 MB).") }
            model = try CADReader.read(url)
        default:
            let scene = try objScene(url)
            return .scene(scene)
        }
        guard !model.isEmpty else { throw ExplorerError("This file has no shapes to show.") }
        return .mesh(model)
    }

    // OBJ through Model I/O, with its materials and textures when their files are next to it.
    private static func objScene(_ url: URL) throws -> SCNScene {
        let asset = MDLAsset(url: url)
        asset.loadTextures()
        for object in asset.childObjects(of: MDLMesh.self) {
            guard let mesh = object as? MDLMesh else { continue }
            if mesh.vertexAttributeData(forAttributeNamed: MDLVertexAttributeNormal) == nil {
                mesh.addNormals(withAttributeNamed: MDLVertexAttributeNormal, creaseThreshold: 0.5)
            }
        }
        let scene = SCNScene(mdlAsset: asset)
        var hasGeometry = false
        scene.rootNode.enumerateHierarchy { node, stop in
            if node.geometry != nil {
                hasGeometry = true
                stop.pointee = true
            }
        }
        guard hasGeometry else { throw ExplorerError("This OBJ file has no shapes to show.") }
        return scene
    }
}

// Shows a 3D model: one finger turns it, two fingers move it, pinch zooms, and double-tap fits it back.
// One-finger drags turn the model, so swiping between files is off here; the ‹ › buttons move instead.
final class Model3DViewController: UIViewController {
    private static let modelColor = UIColor(red: 0.72, green: 0.76, blue: 0.82, alpha: 1)

    // Let go once the model is built, so the file's data doesn't stay in memory twice.
    private var content: Model3DContent?
    private let folder: URL?
    private let sceneView = SCNView()
    private let camera = SCNNode()
    private var home = SCNMatrix4Identity
    private let previousButton = UIButton(type: .system)
    private let nextButton = UIButton(type: .system)
    // One material per color; those in the foreground color follow light and dark mode.
    private var materials: [MaterialKey: SCNMaterial] = [:]

    private struct MaterialKey: Hashable {
        let ink: DXFInk?
        let lit: Bool
    }

    init(content: Model3DContent, folder: URL?) {
        self.content = content
        self.folder = folder
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        sceneView.frame = view.bounds
        sceneView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        sceneView.backgroundColor = UIColor.systemBackground.resolvedColor(with: traitCollection)
        sceneView.allowsCameraControl = true
        sceneView.autoenablesDefaultLighting = true
        sceneView.antialiasingMode = .multisampling4X
        sceneView.accessibilityIdentifier = "model-3d"
        view.addSubview(sceneView)

        let scene = SCNScene()
        let model = SCNNode()
        var zUp = true
        var low = SCNVector3(0, 0, 0)
        var high = SCNVector3(0, 0, 0)
        switch content {
        case let .mesh(mesh)?:
            build(mesh, into: model)
            zUp = mesh.zUp
            let extent = mesh.extent
            low = SCNVector3(Float(extent.low.x), Float(extent.low.y), Float(extent.low.z))
            high = SCNVector3(Float(extent.high.x), Float(extent.high.y), Float(extent.high.z))
        case let .scene(loaded)?:
            let children = loaded.rootNode.childNodes
            for child in children { model.addChildNode(child) }
            // OBJ files usually have Y up already.
            zUp = false
            let box = Self.bounds(of: model)
            low = box.low
            high = box.high
        case nil:
            break
        }
        content = nil
        // The model sits around the middle; files with Z up are stood upright.
        model.position = SCNVector3(-(low.x + high.x) / 2, -(low.y + high.y) / 2, -(low.z + high.z) / 2)
        let holder = SCNNode()
        holder.addChildNode(model)
        if zUp { holder.eulerAngles = SCNVector3(-Float.pi / 2, 0, 0) }
        scene.rootNode.addChildNode(holder)

        let ambient = SCNNode()
        let light = SCNLight()
        light.type = .ambient
        light.intensity = 350
        ambient.light = light
        scene.rootNode.addChildNode(ambient)

        // The camera looks at the whole model from the front, a little from the right and above.
        let dx = high.x - low.x, dy = high.y - low.y, dz = high.z - low.z
        let radius = max((dx * dx + dy * dy + dz * dz).squareRoot() / 2, 0.001)
        let lens = SCNCamera()
        lens.fieldOfView = 45
        lens.automaticallyAdjustsZRange = true
        camera.camera = lens
        let distance = radius / sin(22.5 * Float.pi / 180) * 1.15
        let length = Float(0.36 + 0.2025 + 1.0).squareRoot()
        camera.position = SCNVector3(0.6 / length * distance, 0.45 / length * distance, 1.0 / length * distance)
        camera.look(at: SCNVector3(0, 0, 0))
        scene.rootNode.addChildNode(camera)
        home = camera.transform

        sceneView.scene = scene
        sceneView.pointOfView = camera
        sceneView.defaultCameraController.target = SCNVector3(0, 0, 0)
        sceneView.defaultCameraController.interactionMode = .orbitTurntable
        sceneView.defaultCameraController.inertiaEnabled = true

        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(fitBack))
        doubleTap.numberOfTapsRequired = 2
        sceneView.addGestureRecognizer(doubleTap)

        setUpButton(previousButton, symbol: "chevron.left", action: #selector(showPrevious))
        setUpButton(nextButton, symbol: "chevron.right", action: #selector(showNext))
        previousButton.accessibilityLabel = "Previous file"
        previousButton.accessibilityIdentifier = "model-previous"
        nextButton.accessibilityLabel = "Next file"
        nextButton.accessibilityIdentifier = "model-next"
        NSLayoutConstraint.activate([
            previousButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 8),
            previousButton.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            nextButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -8),
            nextButton.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])

        // The background and the foreground color follow light and dark mode.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _: UITraitCollection) in
            self.applyModeColors()
        }
    }

    private func setUpButton(_ button: UIButton, symbol: String, action: Selector) {
        var configuration = UIButton.Configuration.gray()
        configuration.cornerStyle = .capsule
        configuration.image = UIImage(systemName: symbol)
        button.configuration = configuration
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: action, for: .touchUpInside)
        button.isHidden = true
        view.addSubview(button)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard let page else { return }
        page.lockPaging(true)
        previousButton.isHidden = page.index <= 0
        nextButton.isHidden = page.index >= page.count - 1
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        page?.lockPaging(false)
    }

    // The viewer page this view is on, for the ‹ › buttons.
    private var page: PageController? {
        var node: UIViewController? = parent
        while let current = node {
            if let found = current as? PageController { return found }
            node = current.parent
        }
        return nil
    }

    @objc private func showPrevious() { page?.step?(-1) }
    @objc private func showNext() { page?.step?(1) }

    @objc private func fitBack() {
        sceneView.defaultCameraController.stopInertia()
        let viewpoint = sceneView.pointOfView ?? camera
        SCNTransaction.begin()
        SCNTransaction.animationDuration = 0.3
        viewpoint.transform = home
        viewpoint.camera?.fieldOfView = 45
        SCNTransaction.commit()
        sceneView.defaultCameraController.target = SCNVector3(0, 0, 0)
    }

    private func applyModeColors() {
        sceneView.backgroundColor = UIColor.systemBackground.resolvedColor(with: traitCollection)
        let foreground = UIColor.label.resolvedColor(with: traitCollection)
        for (key, material) in materials where key.ink == DXFInk.foreground { material.diffuse.contents = foreground }
    }

    // MARK: Building the model

    private func material(_ ink: DXFInk?, lit: Bool) -> SCNMaterial {
        let key = MaterialKey(ink: ink, lit: lit)
        if let known = materials[key] { return known }
        let color: UIColor
        switch ink {
        case nil:
            color = Self.modelColor
        case .foreground?:
            color = UIColor.label.resolvedColor(with: traitCollection)
        case let .rgb(r, g, b)?:
            color = UIColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1)
        }
        let made = SCNMaterial()
        made.diffuse.contents = color
        made.lightingModel = lit ? .blinn : .constant
        // The soft fill light uses the model's own color, so shaded sides keep it.
        made.locksAmbientWithDiffuse = true
        made.isDoubleSided = true
        materials[key] = made
        return made
    }

    private func build(_ mesh: Model3D, into node: SCNNode) {
        for surface in mesh.surfaces where surface.positions.count >= 9 {
            node.addChildNode(Self.surfaceNode(surface.positions, material(surface.ink, lit: true)))
        }
        for group in mesh.lines where group.positions.count >= 6 {
            node.addChildNode(Self.lineNode(group.positions, material(group.ink, lit: false), primitive: .line))
        }
        for group in mesh.points where group.positions.count >= 3 {
            node.addChildNode(Self.lineNode(group.positions, material(group.ink, lit: false), primitive: .point))
        }
        // Fills and text are flat shapes, one each; a limit keeps big drawings smooth to turn.
        for fill in mesh.flats.prefix(2000) {
            if let flat = Self.flatNode(fill, offset: mesh.offset, material(fill.ink, lit: false)) { node.addChildNode(flat) }
        }
        for label in mesh.labels.prefix(1000) {
            if let text = Self.textNode(label, offset: mesh.offset, material(label.ink, lit: false)) { node.addChildNode(text) }
        }
        for picture in mesh.pictures {
            node.addChildNode(pictureNode(picture, offset: mesh.offset))
        }
    }

    private static func floatData(_ values: [Float], count: Int) -> Data {
        values.withUnsafeBufferPointer { Data(buffer: UnsafeBufferPointer(rebasing: $0[0..<count])) }
    }

    // Indices 0, 1, 2… for vertices that are listed in drawing order.
    private static func element(_ vertexCount: Int, _ primitive: SCNGeometryPrimitiveType, primitives: Int) -> SCNGeometryElement {
        var indices = Data(count: vertexCount * 4)
        indices.withUnsafeMutableBytes { raw in
            let list = raw.bindMemory(to: UInt32.self)
            for i in 0..<vertexCount { list[i] = UInt32(i) }
        }
        return SCNGeometryElement(data: indices, primitiveType: primitive, primitiveCount: primitives, bytesPerIndex: 4)
    }

    private static func source(_ data: Data, _ semantic: SCNGeometrySource.Semantic, count: Int) -> SCNGeometrySource {
        SCNGeometrySource(data: data, semantic: semantic, vectorCount: count, usesFloatComponents: true,
                          componentsPerVector: 3, bytesPerComponent: 4, dataOffset: 0, dataStride: 12)
    }

    // Triangles with one normal per face, so edges stay crisp.
    private static func surfaceNode(_ positions: [Float], _ material: SCNMaterial) -> SCNNode {
        let vertexCount = (positions.count / 9) * 3
        var normals = Data(count: vertexCount * 12)
        normals.withUnsafeMutableBytes { raw in
            let n = raw.bindMemory(to: Float.self)
            var t = 0
            while t < vertexCount * 3 {
                let ax = positions[t], ay = positions[t + 1], az = positions[t + 2]
                let ux = positions[t + 3] - ax, uy = positions[t + 4] - ay, uz = positions[t + 5] - az
                let vx = positions[t + 6] - ax, vy = positions[t + 7] - ay, vz = positions[t + 8] - az
                var nx = uy * vz - uz * vy, ny = uz * vx - ux * vz, nz = ux * vy - uy * vx
                let size = (nx * nx + ny * ny + nz * nz).squareRoot()
                if size > 0 {
                    nx /= size
                    ny /= size
                    nz /= size
                } else {
                    nx = 0
                    ny = 0
                    nz = 1
                }
                for k in 0..<3 {
                    n[t + k * 3] = nx
                    n[t + k * 3 + 1] = ny
                    n[t + k * 3 + 2] = nz
                }
                t += 9
            }
        }
        let vertices = source(floatData(positions, count: vertexCount * 3), .vertex, count: vertexCount)
        let geometry = SCNGeometry(sources: [vertices, source(normals, .normal, count: vertexCount)],
                                   elements: [element(vertexCount, .triangles, primitives: vertexCount / 3)])
        geometry.materials = [material]
        return SCNNode(geometry: geometry)
    }

    // Lines are two ends per segment; points one each.
    private static func lineNode(_ positions: [Float], _ material: SCNMaterial, primitive: SCNGeometryPrimitiveType) -> SCNNode {
        let perPrimitive = primitive == .line ? 2 : 1
        let vertexCount = (positions.count / (3 * perPrimitive)) * perPrimitive
        let shape = element(vertexCount, primitive, primitives: vertexCount / perPrimitive)
        if primitive == .point {
            shape.pointSize = 4
            shape.minimumPointScreenSpaceRadius = 2
            shape.maximumPointScreenSpaceRadius = 4
        }
        let vertices = source(floatData(positions, count: vertexCount * 3), .vertex, count: vertexCount)
        let geometry = SCNGeometry(sources: [vertices], elements: [shape])
        geometry.materials = [material]
        return SCNNode(geometry: geometry)
    }

    // The axes and shift of a flat thing in the model.
    private static func placement(_ x: DXFVec, _ y: DXFVec, _ z: DXFVec, _ origin: DXFVec) -> SCNMatrix4 {
        SCNMatrix4(m11: Float(x.x), m12: Float(x.y), m13: Float(x.z), m14: 0,
                   m21: Float(y.x), m22: Float(y.y), m23: Float(y.z), m24: 0,
                   m31: Float(z.x), m32: Float(z.y), m33: Float(z.z), m34: 0,
                   m41: Float(origin.x), m42: Float(origin.y), m43: Float(origin.z), m44: 1)
    }

    // A fill (hatch or solid) as a flat shape in its own plane; holes stay open.
    private static func flatNode(_ fill: DXFFill, offset: DXFVec, _ material: SCNMaterial) -> SCNNode? {
        guard let first = fill.rings.first(where: { $0.count >= 3 }) else { return nil }
        // The plane's direction from the outline (Newell's method).
        var normal = DXFVec()
        for i in 0..<first.count {
            let a = first[i], b = first[(i + 1) % first.count]
            normal.x += (a.y - b.y) * (a.z + b.z)
            normal.y += (a.z - b.z) * (a.x + b.x)
            normal.z += (a.x - b.x) * (a.y + b.y)
        }
        let plane = DXFMatrix.ocs(normal.length > 0 ? normal : DXFVec(0, 0, 1))
        let origin = first[0] - offset
        let path = UIBezierPath()
        path.usesEvenOddFillRule = true
        for ring in fill.rings where ring.count >= 3 {
            for (index, point) in ring.enumerated() {
                let relative = point - offset - origin
                let flat = CGPoint(x: relative.dot(plane.ax), y: relative.dot(plane.ay))
                if index == 0 { path.move(to: flat) } else { path.addLine(to: flat) }
            }
            path.close()
        }
        let shape = SCNShape(path: path, extrusionDepth: 0)
        shape.materials = [material]
        let node = SCNNode(geometry: shape)
        node.transform = placement(plane.ax, plane.ay, plane.az, origin)
        return node
    }

    // Text as flat letter outlines, standing where the drawing puts it.
    private static func textNode(_ label: DXFLabel, offset: DXFVec, _ material: SCNMaterial) -> SCNNode? {
        guard let shape = DXFTextShape.local(label) else { return nil }
        let geometry = SCNShape(path: UIBezierPath(cgPath: shape.path), extrusionDepth: 0)
        geometry.materials = [material]
        let node = SCNNode(geometry: geometry)
        let x = label.xAxis * Double(shape.sx), y = label.yAxis * Double(shape.sy)
        let z = label.xAxis.cross(label.yAxis).unit
        node.transform = placement(x, y, z.length > 0 ? z : DXFVec(0, 0, 1), label.origin - offset)
        return node
    }

    // A picture on its rectangle, or a frame when its file isn't next to the drawing.
    private func pictureNode(_ picture: DXFPicture, offset: DXFVec) -> SCNNode {
        let a = picture.corner - offset
        let b = a + picture.u
        let c = b + picture.v
        let d = a + picture.v
        if let folder, !picture.file.isEmpty,
           let image = UIImage(contentsOfFile: folder.appendingPathComponent(picture.file).path) {
            let corners = [a, b, c, d].map { SCNVector3(Float($0.x), Float($0.y), Float($0.z)) }
            // The picture's top edge is its upper side.
            let mapping = SCNGeometrySource(textureCoordinates: [CGPoint(x: 0, y: 1), CGPoint(x: 1, y: 1),
                                                                 CGPoint(x: 1, y: 0), CGPoint(x: 0, y: 0)])
            let face = SCNGeometryElement(indices: [UInt32(0), 1, 2, 0, 2, 3], primitiveType: .triangles)
            let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: corners), mapping], elements: [face])
            let surface = SCNMaterial()
            surface.diffuse.contents = image
            surface.lightingModel = .constant
            surface.isDoubleSided = true
            geometry.materials = [surface]
            return SCNNode(geometry: geometry)
        }
        var frame: [Float] = []
        for (from, to) in [(a, b), (b, c), (c, d), (d, a)] {
            frame += [Float(from.x), Float(from.y), Float(from.z), Float(to.x), Float(to.y), Float(to.z)]
        }
        return Self.lineNode(frame, material(picture.ink, lit: false), primitive: .line)
    }

    // The box around everything with a shape, in the model's own coordinates.
    private static func bounds(of root: SCNNode) -> (low: SCNVector3, high: SCNVector3) {
        var low = SCNVector3(Float.infinity, Float.infinity, Float.infinity)
        var high = SCNVector3(-Float.infinity, -Float.infinity, -Float.infinity)
        root.enumerateHierarchy { node, _ in
            guard node.geometry != nil else { return }
            let box = node.boundingBox
            for x in [box.min.x, box.max.x] {
                for y in [box.min.y, box.max.y] {
                    for z in [box.min.z, box.max.z] {
                        let p = node.convertPosition(SCNVector3(x, y, z), to: root)
                        guard p.x.isFinite, p.y.isFinite, p.z.isFinite else { continue }
                        low = SCNVector3(min(low.x, p.x), min(low.y, p.y), min(low.z, p.z))
                        high = SCNVector3(max(high.x, p.x), max(high.y, p.y), max(high.z, p.z))
                    }
                }
            }
        }
        if low.x > high.x { return (low: SCNVector3(0, 0, 0), high: SCNVector3(0, 0, 0)) }
        return (low: low, high: high)
    }
}
