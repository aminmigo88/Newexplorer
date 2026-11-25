import UIKit
import CoreText

// Shows a DXF drawing: it fits the screen, zooms with two fingers and double-tap, and pages when not zoomed.
// Lines keep their on-screen thickness at every zoom; dashes, text and pictures grow with the drawing.
final class DXFViewController: UIViewController, UIScrollViewDelegate {
    private static let thin: CGFloat = 0.75
    private static let dotSize: CGFloat = 3

    private struct StrokeKey: Hashable {
        let look: DXFLook
        let width: Double
    }
    // A line layer: its width drawn to scale (polyline widths), and its on-screen width.
    private struct Stroke {
        let layer: CAShapeLayer
        let drawn: CGFloat
        let screen: CGFloat
    }

    private let drawing: DXFDrawing
    private let folder: URL?
    private let scroll = UIScrollView()
    private let canvas = UIView()
    private let sheetButton = UIButton(type: .system)
    private let modeSwitch = UISegmentedControl(items: ["2D", "3D"])
    private var threeD: Model3DViewController?
    private let caption = UILabel()
    private var sheet = 0
    private var strokes: [Stroke] = []
    private var laidOutSize = CGSize.zero
    private var widthsZoom: CGFloat = 1

    init(drawing: DXFDrawing, folder: URL?) {
        self.drawing = drawing
        self.folder = folder
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        scroll.frame = view.bounds
        scroll.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        scroll.delegate = self
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.decelerationRate = .fast
        scroll.addSubview(canvas)
        view.addSubview(scroll)
        let doubleTap = UITapGestureRecognizer(target: self, action: #selector(toggleZoom(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)

        caption.font = .preferredFont(forTextStyle: .footnote)
        caption.textColor = .secondaryLabel
        caption.translatesAutoresizingMaskIntoConstraints = false
        caption.accessibilityIdentifier = "dxf-size"
        view.addSubview(caption)

        var configuration = UIButton.Configuration.gray()
        configuration.cornerStyle = .capsule
        configuration.image = UIImage(systemName: "rectangle.stack")
        configuration.imagePadding = 6
        sheetButton.configuration = configuration
        sheetButton.showsMenuAsPrimaryAction = true
        sheetButton.translatesAutoresizingMaskIntoConstraints = false
        sheetButton.accessibilityIdentifier = "dxf-sheet"
        sheetButton.isHidden = drawing.sheets.count < 2
        view.addSubview(sheetButton)

        modeSwitch.selectedSegmentIndex = 0
        modeSwitch.translatesAutoresizingMaskIntoConstraints = false
        modeSwitch.accessibilityIdentifier = "dxf-mode"
        modeSwitch.addTarget(self, action: #selector(modeChanged), for: .valueChanged)
        view.addSubview(modeSwitch)

        NSLayoutConstraint.activate([
            modeSwitch.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            modeSwitch.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8),
            caption.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            caption.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -8),
            sheetButton.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            sheetButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 8)
        ])
        updateSheetMenu()
        // The foreground color follows light and dark mode.
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (self: Self, _: UITraitCollection) in
            self.render()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard scroll.bounds.size != laidOutSize else { return }
        laidOutSize = scroll.bounds.size
        render()
    }

    private func updateSheetMenu() {
        guard drawing.sheets.indices.contains(sheet) else { return }
        var configuration = sheetButton.configuration ?? UIButton.Configuration.gray()
        configuration.title = drawing.sheets[sheet].name
        sheetButton.configuration = configuration
        sheetButton.accessibilityLabel = "Sheet"
        sheetButton.accessibilityValue = drawing.sheets[sheet].name
        let actions = drawing.sheets.indices.map { index in
            UIAction(title: drawing.sheets[index].name, state: index == sheet ? .on : .off) { [weak self] _ in
                guard let self else { return }
                // Layouts are sheets of paper, so they show in 2D.
                self.modeSwitch.selectedSegmentIndex = 0
                self.hide3D()
                self.sheet = index
                self.updateSheetMenu()
                self.render()
            }
        }
        sheetButton.menu = UIMenu(children: actions)
    }

    // MARK: Drawing

    private func render() {
        guard laidOutSize.width > 0, laidOutSize.height > 0, drawing.sheets.indices.contains(sheet) else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        canvas.layer.sublayers?.forEach { $0.removeFromSuperlayer() }
        strokes = []
        scroll.zoomScale = 1
        widthsZoom = 1
        let current = drawing.sheets[sheet]
        var box = current.box
        if box.isEmpty {
            box.add(DXFVec(0, 0))
            box.add(DXFVec(1, 1))
        }
        let margin: CGFloat = 16
        let width = CGFloat(max(box.width, 1e-9)), height = CGFloat(max(box.height, 1e-9))
        let room = CGSize(width: max(laidOutSize.width - 2 * margin, 1), height: max(laidOutSize.height - 2 * margin, 1))
        let k = min(room.width / width, room.height / height)
        let size = CGSize(width: width * k + 2 * margin, height: height * k + 2 * margin)
        canvas.frame = CGRect(origin: .zero, size: size)
        scroll.contentSize = size
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 500
        // Drawing coordinates run up; the screen's run down.
        let world = CGAffineTransform(a: k, b: 0, c: 0, d: -k,
                                      tx: margin - CGFloat(box.minX) * k, ty: margin + CGFloat(box.maxY) * k)
        let foreground = UIColor.label.resolvedColor(with: traitCollection)
        for viewport in current.viewports { addViewport(viewport, world: world, k: k, foreground: foreground) }
        if let paper = current.paper {
            var outline = DXFScene()
            let corners = [DXFVec(paper.minX, paper.minY), DXFVec(paper.maxX, paper.minY),
                           DXFVec(paper.maxX, paper.maxY), DXFVec(paper.minX, paper.maxY)]
            outline.paths = [DXFPath(points: corners, closed: true, look: DXFLook(ink: .rgb(150, 150, 150), weight: 0, dashes: []),
                                     width: 0, layer: "")]
            draw(outline, into: canvas.layer, transform: world, scale: k, hidden: [], foreground: foreground)
        }
        draw(current.scene, into: canvas.layer, transform: world, scale: k, hidden: [], foreground: foreground)
        caption.text = current.isModel ? drawing.sizeText : nil
        caption.isHidden = caption.text == nil
        modeSwitch.isHidden = !current.isModel
        center()
        applyWidths()
    }

    // A layout window shows the main drawing, cut to its frame and scaled.
    private func addViewport(_ viewport: DXFViewport, world: CGAffineTransform, k: CGFloat, foreground: UIColor) {
        let c = viewport.center
        let low = CGPoint(x: c.x - viewport.width / 2, y: c.y - viewport.height / 2).applying(world)
        let high = CGPoint(x: c.x + viewport.width / 2, y: c.y + viewport.height / 2).applying(world)
        let frame = CGRect(x: min(low.x, high.x), y: min(low.y, high.y), width: abs(high.x - low.x), height: abs(high.y - low.y))
        guard frame.width > 0, frame.height > 0 else { return }
        let container = CALayer()
        container.frame = frame
        container.masksToBounds = true
        let scale = CGFloat(viewport.scale)
        let toPaper = CGAffineTransform(translationX: CGFloat(-viewport.target.x), y: CGFloat(-viewport.target.y))
            .concatenating(CGAffineTransform(rotationAngle: CGFloat(-viewport.twist)))
            .concatenating(CGAffineTransform(translationX: CGFloat(-viewport.viewCenter.x), y: CGFloat(-viewport.viewCenter.y)))
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: CGFloat(c.x), y: CGFloat(c.y)))
        let transform = toPaper.concatenating(world).concatenating(CGAffineTransform(translationX: -frame.minX, y: -frame.minY))
        draw(drawing.model, into: container, transform: transform, scale: k * scale, hidden: viewport.hidden, foreground: foreground)
        canvas.layer.addSublayer(container)
    }

    private func color(_ ink: DXFInk, _ foreground: UIColor) -> CGColor {
        switch ink {
        case .foreground:
            return foreground.cgColor
        case let .rgb(r, g, b):
            return UIColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1).cgColor
        }
    }

    // Fills, then pictures, lines, dots and text; one layer for each color and line look.
    private func draw(_ scene: DXFScene, into parent: CALayer, transform: CGAffineTransform, scale: CGFloat,
                      hidden: Set<String>, foreground: UIColor) {
        var fills: [DXFInk: CGMutablePath] = [:]
        for fill in scene.fills where !hidden.contains(fill.layer) {
            let path = fills[fill.ink] ?? CGMutablePath()
            for ring in fill.rings where ring.count >= 3 {
                path.addLines(between: ring.map { CGPoint(x: $0.x, y: $0.y) }, transform: transform)
                path.closeSubpath()
            }
            fills[fill.ink] = path
        }
        for (ink, path) in fills {
            let layer = CAShapeLayer()
            layer.path = path
            layer.fillColor = color(ink, foreground)
            layer.fillRule = .evenOdd
            layer.strokeColor = nil
            parent.addSublayer(layer)
        }

        // A picture that isn't in the drawing's folder shows as a frame with its file name.
        var frames: [DXFPath] = []
        var names: [DXFLabel] = []
        for picture in scene.pictures where !hidden.contains(picture.layer) {
            if let image = loadImage(picture.file) {
                addImage(image, picture, to: parent, transform: transform)
            } else {
                let across = picture.corner + picture.u
                let up = picture.corner + picture.v
                let far = across + picture.v
                frames.append(DXFPath(points: [picture.corner, across, far, up], closed: true,
                                      look: DXFLook(ink: picture.ink, weight: 0, dashes: []), width: 0, layer: picture.layer))
                let middle = picture.corner + (picture.u + picture.v) * 0.5
                let height = min(picture.u.length, picture.v.length) * 0.08
                names.append(DXFLabel(text: picture.file.isEmpty ? "Picture" : picture.file, origin: middle,
                                      xAxis: picture.u.unit, yAxis: picture.v.unit, height: height, widthFactor: 1,
                                      horizontal: 1, vertical: 2, wrap: 0, spacing: 1, fit: 0, stretch: false,
                                      ink: picture.ink, layer: picture.layer))
            }
        }

        var groups: [StrokeKey: CGMutablePath] = [:]
        func addLine(_ line: DXFPath) {
            guard !hidden.contains(line.layer), line.points.count >= 2 else { return }
            let key = StrokeKey(look: line.look, width: line.width)
            let path = groups[key] ?? CGMutablePath()
            path.move(to: CGPoint(x: line.points[0].x, y: line.points[0].y), transform: transform)
            for point in line.points.dropFirst() {
                path.addLine(to: CGPoint(x: point.x, y: point.y), transform: transform)
            }
            if line.closed { path.closeSubpath() }
            groups[key] = path
        }
        for line in scene.paths { addLine(line) }
        for line in frames { addLine(line) }
        for (key, path) in groups {
            let layer = CAShapeLayer()
            layer.path = path
            layer.fillColor = nil
            layer.strokeColor = color(key.look.ink, foreground)
            layer.lineCap = .round
            layer.lineJoin = .round
            if !key.look.dashes.isEmpty {
                layer.lineDashPattern = key.look.dashes.map { NSNumber(value: Double(CGFloat($0) * scale)) }
            }
            let screen = key.look.weight > 0 ? CGFloat(key.look.weight) : Self.thin
            strokes.append(Stroke(layer: layer, drawn: CGFloat(key.width) * scale, screen: screen))
            parent.addSublayer(layer)
        }

        var dots: [DXFInk: CGMutablePath] = [:]
        for dot in scene.dots where !hidden.contains(dot.layer) {
            let path = dots[dot.ink] ?? CGMutablePath()
            let point = CGPoint(x: dot.point.x, y: dot.point.y)
            path.move(to: point, transform: transform)
            path.addLine(to: point, transform: transform)
            dots[dot.ink] = path
        }
        for (ink, path) in dots {
            let layer = CAShapeLayer()
            layer.path = path
            layer.fillColor = nil
            layer.strokeColor = color(ink, foreground)
            layer.lineCap = .round
            strokes.append(Stroke(layer: layer, drawn: 0, screen: Self.dotSize))
            parent.addSublayer(layer)
        }

        var texts: [DXFInk: CGMutablePath] = [:]
        for label in scene.labels + names where !hidden.contains(label.layer) {
            guard let shape = DXFTextShape.path(label) else { continue }
            let path = texts[label.ink] ?? CGMutablePath()
            path.addPath(shape, transform: transform)
            texts[label.ink] = path
        }
        for (ink, path) in texts {
            let layer = CAShapeLayer()
            layer.path = path
            layer.fillColor = color(ink, foreground)
            layer.strokeColor = nil
            parent.addSublayer(layer)
        }
    }

    // Pictures are read from the drawing's folder, by file name.
    private func loadImage(_ file: String) -> CGImage? {
        guard let folder, !file.isEmpty else { return nil }
        return UIImage(contentsOfFile: folder.appendingPathComponent(file).path)?.cgImage
    }

    private func addImage(_ image: CGImage, _ picture: DXFPicture, to parent: CALayer, transform: CGAffineTransform) {
        let corner = CGPoint(x: picture.corner.x, y: picture.corner.y).applying(transform)
        let across = CGPoint(x: picture.corner.x + picture.u.x, y: picture.corner.y + picture.u.y).applying(transform)
        let up = CGPoint(x: picture.corner.x + picture.v.x, y: picture.corner.y + picture.v.y).applying(transform)
        // The image's top-left goes to the picture's upper corner, its bottom-left to the lower one.
        let layer = CALayer()
        layer.contents = image
        layer.contentsGravity = .resize
        layer.anchorPoint = .zero
        layer.bounds = CGRect(x: 0, y: 0, width: 1, height: 1)
        layer.position = .zero
        layer.setAffineTransform(CGAffineTransform(a: across.x - corner.x, b: across.y - corner.y,
                                                   c: corner.x - up.x, d: corner.y - up.y, tx: up.x, ty: up.y))
        layer.minificationFilter = .trilinear
        parent.addSublayer(layer)
    }

    // MARK: 2D and 3D

    @objc private func modeChanged() {
        if modeSwitch.selectedSegmentIndex == 1 { show3D() } else { hide3D() }
    }

    // The main drawing turned around in 3D, over the 2D view; the switch and the sheet button stay on top.
    private func show3D() {
        guard threeD == nil else { return }
        let controller = Model3DViewController(content: .mesh(Model3D(dxf: drawing.model)), folder: folder)
        addChild(controller)
        controller.view.frame = view.bounds
        controller.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.insertSubview(controller.view, aboveSubview: scroll)
        controller.didMove(toParent: self)
        threeD = controller
    }

    private func hide3D() {
        guard let controller = threeD else { return }
        controller.willMove(toParent: nil)
        controller.view.removeFromSuperview()
        controller.removeFromParent()
        threeD = nil
        // Swiping between files works again in 2D.
        var node: UIViewController? = parent
        while let current = node {
            if let page = current as? PageController {
                page.lockPaging(false)
                break
            }
            node = current.parent
        }
    }

    // MARK: Zoom

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { canvas }

    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        center()
        // Line widths are updated in steps while pinching, and exactly when the pinch ends.
        let ratio = scroll.zoomScale / widthsZoom
        if ratio > 1.15 || ratio < 0.87 { applyWidths() }
    }

    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        applyWidths()
    }

    private func applyWidths() {
        let zoom = max(scroll.zoomScale, 0.01)
        widthsZoom = zoom
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for stroke in strokes { stroke.layer.lineWidth = max(stroke.drawn, stroke.screen / zoom) }
        CATransaction.commit()
    }

    private func center() {
        let bounds = scroll.bounds.size
        let content = scroll.contentSize
        let x = max(0, (bounds.width - content.width) / 2)
        let y = max(0, (bounds.height - content.height) / 2)
        scroll.contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
    }

    @objc private func toggleZoom(_ gesture: UITapGestureRecognizer) {
        if scroll.zoomScale > 1 {
            scroll.setZoomScale(1, animated: true)
        } else {
            let point = gesture.location(in: canvas)
            let size = CGSize(width: scroll.bounds.width / 3, height: scroll.bounds.height / 3)
            scroll.zoom(to: CGRect(x: point.x - size.width / 2, y: point.y - size.height / 2,
                                   width: size.width, height: size.height), animated: true)
        }
    }
}

// Text as glyph outlines in drawing coordinates, so it stays sharp at every zoom.
enum DXFTextShape {
    private static let font = UIFont.systemFont(ofSize: 100)

    static func path(_ label: DXFLabel) -> CGPath? {
        guard let shape = local(label) else { return nil }
        let x = label.xAxis, y = label.yAxis, o = label.origin
        var toDrawing = CGAffineTransform(a: CGFloat(x.x) * shape.sx, b: CGFloat(x.y) * shape.sx,
                                          c: CGFloat(y.x) * shape.sy, d: CGFloat(y.y) * shape.sy,
                                          tx: CGFloat(o.x), ty: CGFloat(o.y))
        return shape.path.copy(using: &toDrawing)
    }

    // The outline in font units, aligned on its anchor, and the scale along the text and up from it.
    static func local(_ label: DXFLabel) -> (path: CGPath, sx: CGFloat, sy: CGFloat)? {
        let cap = font.capHeight
        guard cap > 0, label.height > 0 else { return nil }
        let unit = CGFloat(label.height) / cap
        let factor = CGFloat(label.widthFactor > 0 ? label.widthFactor : 1)
        let lineHeight = cap * 5 / 3 * CGFloat(label.spacing)
        var lines: [String] = []
        for paragraph in label.text.components(separatedBy: "\n") {
            if label.wrap > 0 {
                lines += wrapped(paragraph, width: CGFloat(label.wrap) / unit / factor)
            } else {
                lines.append(paragraph)
            }
        }
        let shapes = lines.map { glyphs($0) }
        let widest = shapes.map { $0.width }.max() ?? 0
        guard widest > 0 else { return nil }
        let descent = font.descender < 0 ? -font.descender : font.descender
        let extra = CGFloat(shapes.count - 1) * lineHeight
        let firstBaseline: CGFloat
        switch label.vertical {
        case 3: firstBaseline = -cap
        case 2: firstBaseline = -cap / 2 + extra / 2
        case 1: firstBaseline = descent + extra
        default: firstBaseline = 0
        }
        let combined = CGMutablePath()
        for (index, shape) in shapes.enumerated() {
            let x: CGFloat
            switch label.horizontal {
            case 1: x = -shape.width / 2
            case 2: x = -shape.width
            default: x = 0
            }
            let y = firstBaseline - CGFloat(index) * lineHeight
            combined.addPath(shape.path, transform: CGAffineTransform(translationX: x, y: y))
        }
        var sx = unit * factor
        var sy = unit
        // Fit text is stretched to its two points; aligned text also grows in height.
        if label.fit > 0 {
            let natural = widest * sx
            if natural > 0 {
                let stretch = CGFloat(label.fit) / natural
                sx *= stretch
                if label.stretch { sy *= stretch }
            }
        }
        return (path: combined as CGPath, sx: sx, sy: sy)
    }

    private static func glyphs(_ text: String) -> (path: CGPath, width: CGFloat) {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        let path = CGMutablePath()
        let runs = (CTLineGetGlyphRuns(line) as? [CTRun]) ?? []
        for run in runs {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard let value = attributes[kCTFontAttributeName as String] else { continue }
            let runFont = value as! CTFont
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            for index in 0..<count {
                var place = CGAffineTransform(translationX: positions[index].x, y: positions[index].y)
                if let outline = CTFontCreatePathForGlyph(runFont, glyphs[index], &place) { path.addPath(outline) }
            }
        }
        return (path, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
    }

    private static func width(_ text: String) -> CGFloat {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        return CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    }

    // Splits a paragraph into lines no wider than the text box.
    private static func wrapped(_ paragraph: String, width limit: CGFloat) -> [String] {
        let words = paragraph.components(separatedBy: " ")
        var lines: [String] = []
        var current = ""
        for word in words {
            let candidate = current.isEmpty ? word : current + " " + word
            if !current.isEmpty && width(candidate) > limit {
                lines.append(current)
                current = word
            } else {
                current = candidate
            }
        }
        lines.append(current)
        return lines
    }
}

// A small picture of a DXF drawing for file lists: its lines and fills, without text.
enum DXFThumbnail {
    static func image(_ url: URL, side: CGFloat, dark: Bool) -> UIImage? {
        guard side > 4, let drawing = try? DXFDrawing.load(url),
              let sheet = drawing.sheets.first(where: { !$0.scene.isEmpty }) else { return nil }
        let scene = sheet.scene
        let box = scene.box
        guard !box.isEmpty else { return nil }
        let format = UIGraphicsImageRendererFormat.preferred()
        format.scale = 1
        format.opaque = false
        let foreground = dark ? UIColor.white : UIColor.black
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format)
        return renderer.image { context in
            let cg = context.cgContext
            let inset = side * 0.06
            let span = CGFloat(max(box.width, box.height, 1e-9))
            let k = (side - 2 * inset) / span
            let dx = (side - CGFloat(box.width) * k) / 2
            let dy = (side - CGFloat(box.height) * k) / 2
            let transform = CGAffineTransform(a: k, b: 0, c: 0, d: -k, tx: dx - CGFloat(box.minX) * k, ty: dy + CGFloat(box.maxY) * k)
            for fill in scene.fills {
                let path = CGMutablePath()
                for ring in fill.rings where ring.count >= 3 {
                    path.addLines(between: ring.map { CGPoint(x: $0.x, y: $0.y) }, transform: transform)
                    path.closeSubpath()
                }
                cg.addPath(path)
                cg.setFillColor(color(fill.ink, foreground))
                cg.fillPath(using: .evenOdd)
            }
            cg.setLineWidth(max(1, side / 90))
            cg.setLineCap(.round)
            cg.setLineJoin(.round)
            for line in scene.paths where line.points.count >= 2 {
                let path = CGMutablePath()
                path.addLines(between: line.points.map { CGPoint(x: $0.x, y: $0.y) }, transform: transform)
                if line.closed { path.closeSubpath() }
                cg.addPath(path)
                cg.setStrokeColor(color(line.look.ink, foreground))
                cg.strokePath()
            }
        }
    }

    private static func color(_ ink: DXFInk, _ foreground: UIColor) -> CGColor {
        switch ink {
        case .foreground:
            return foreground.cgColor
        case let .rgb(r, g, b):
            return UIColor(red: CGFloat(r) / 255, green: CGFloat(g) / 255, blue: CGFloat(b) / 255, alpha: 1).cgColor
        }
    }
}
