// Import SVG (and .svgz): the drawings become free paths with the common painting rule
// (Model/VectorImport.swift). The SVG's top-left goes at the page's top-left.
// Reads svg, g, a, switch, use (also of symbol), path (the whole grammar; arcs become cubics), rect (rounded
// corners), circle, ellipse, line, polyline and polygon, with transform; styles from attributes, from the CSS in
// <style> (.class, #id, tag, tag.class, *) and from style=, inherited as in the browser. A gradient becomes the average
// of its stops' colors. text and image don't go in (counted); defs, clipPath, mask, pattern and marker don't draw.
// Units: mm, cm, in, pt, pc and px (1/96"; in Illustrator's files and in those without a size, 1 px = 1 pt, as it exports).
// Cutline has no clipping masks and paints every fill even-odd, so clip-path (and the viewport of a nested svg or of a
// symbol) and fill-rule (nonzero by default in SVG) are baked into the geometry (Model/ImportClipping.swift).
import CoreGraphics
import Foundation

nonisolated enum SVGImport {
    static func read(_ payload: Data) throws -> VectorImport {
        let builder = Builder()
        let parser = XMLParser(data: payload)
        parser.delegate = builder
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        let ok = parser.parse()
        // An error midway (a strange entity, a truncated end) still keeps what came before.
        guard let root = builder.root, root.name == "svg", ok || !root.children.isEmpty else { throw VectorImporter.Failure.svg }
        // Illustrator exports 1 unit = 1 pt; in "Export As" it writes neither the comment nor the size
        // (only the viewBox). Without a size of its own, its convention applies; with a size in px, CSS's (1/96").
        let text = String(decoding: payload.prefix(4096), as: UTF8.self)
        let fromIllustrator = text.contains("Adobe Illustrator") || root["data-name"] != nil || (root["width"] == nil && root["height"] == nil)
        var reader = Reader(root: root, dpi: fromIllustrator ? 72 : 96)
        reader.render()
        return reader.result
    }

    // MARK: Tree

    nonisolated final class Node {
        let name: String
        let attributes: [String: String]
        var children: [Node] = []
        var text = ""

        init(name: String, attributes: [String: String]) {
            // "svg:path" → "path" (files with the namespace prefix).
            self.name = name.split(separator: ":").last.map(String.init) ?? name
            self.attributes = attributes
        }

        subscript(_ key: String) -> String? { attributes[key] }
        var classes: [String] { (attributes["class"] ?? "").split(whereSeparator: \.isWhitespace).map(String.init) }
        var href: String? { attributes["href"] ?? attributes["xlink:href"] }
    }

    nonisolated final class Builder: NSObject, XMLParserDelegate {
        var root: Node?
        private var stack: [Node] = []

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String] = [:]) {
            let node = Node(name: name, attributes: attributes)
            if let parent = stack.last { parent.children.append(node) } else if root == nil { root = node }
            stack.append(node)
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            _ = stack.popLast()
        }

        func parser(_ parser: XMLParser, foundCharacters text: String) {
            if let node = stack.last, node.name == "style" { node.text += text }
        }

        func parser(_ parser: XMLParser, foundCDATA payload: Data) {
            if let node = stack.last, node.name == "style" { node.text += String(decoding: payload, as: UTF8.self) }
        }
    }

    // MARK: Style

    nonisolated enum Paint {
        case noneSelected, color(CMYK), current, url(String)
    }

    nonisolated struct ObjectStyle {
        var fill = Paint.color(CMYK(c: 0, m: 0, y: 0, k: 100))
        var stroke = Paint.noneSelected
        /// In user units.
        var strokeWidth = 1.0
        var color = CMYK(c: 0, m: 0, y: 0, k: 100)
        var visible = true
        var fillOpacity = 1.0
        var strokeOpacity = 1.0
        /// fill-rule: evenodd (SVG's default is nonzero).
        var evenOdd = false
    }

    /// CSS rule: only simple selectors (the last part of a compound selector, without pseudo-classes).
    nonisolated struct Rule {
        nonisolated struct CSSSelector {
            var tag: String?
            var id: String?
            var classes: [String] = []
        }

        var pickers: [CSSSelector]
        var declarations: [(String, String)]

        func valley(to node: Node) -> Bool {
            let classes = node.classes
            return pickers.contains { s in
                (s.tag == nil || s.tag == node.name) && (s.id == nil || s.id == node["id"]) && s.classes.allSatisfy(classes.contains)
            }
        }
    }

    static func rules(_ css: String) -> [Rule] {
        var text = css
        while let a = text.range(of: "/*") {
            let b = text.range(of: "*/", range: a.upperBound..<text.endIndex)?.upperBound ?? text.endIndex
            text.removeSubrange(a.lowerBound..<b)
        }
        var rules: [Rule] = []
        var i = text.startIndex
        while i < text.endIndex {
            guard let opens = text[i...].firstIndex(of: "{") else { break }
            let picker = text[i..<opens].trimmingCharacters(in: .whitespacesAndNewlines)
            // Balanced block (@media rules carry blocks inside).
            var depth = 0, closes = opens
            for j in text[opens...].indices {
                if text[j] == "{" { depth += 1 } else if text[j] == "}" { depth -= 1; if depth == 0 { closes = j; break } }
            }
            // Without the closing brace: the rest of the text is the last rule's body.
            let incomplete = closes == opens
            let pointSize = String(text[text.index(after: opens)..<(incomplete ? text.endIndex : closes)])
            i = incomplete ? text.endIndex : text.index(after: closes)
            if picker.hasPrefix("@") {
                if picker.hasPrefix("@media") { rules += Self.rules(pointSize) }
                continue
            }
            let pickers = picker.split(separator: ",").compactMap { Self.picker(String($0)) }
            guard !pickers.isEmpty else { continue }
            rules.append(Rule(pickers: pickers, declarations: declarations(pointSize)))
        }
        return rules
    }

    private static func picker(_ text: String) -> Rule.CSSSelector? {
        guard let lastOne = text.split(whereSeparator: { $0.isWhitespace || $0 == ">" || $0 == "+" || $0 == "~" }).last,
              !lastOne.contains(":"), !lastOne.contains("[") else { return nil }
        var s = Rule.CSSSelector()
        var current = "", kind: Character = "t"
        func close() {
            if !current.isEmpty {
                switch kind {
                case "#": s.id = current
                case ".": s.classes.append(current)
                default: if current != "*" { s.tag = current }
                }
            }
            current = ""
        }
        for c in lastOne {
            if c == "." || c == "#" { close(); kind = c } else { current.append(c) }
        }
        close()
        return s
    }

    static func declarations(_ text: String) -> [(String, String)] {
        text.split(separator: ";").compactMap { item in
            guard let two = item.firstIndex(of: ":") else { return nil }
            let name = item[..<two].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = item[item.index(after: two)...].replacingOccurrences(of: "!important", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty ? nil : (name, value)
        }
    }

    // MARK: Reading

    nonisolated struct Reader {
        let root: Node
        /// Points per inch for px (96 by the CSS default; 72 in Illustrator's SVGs).
        let dpi: Double
        var result = VectorImport()
        private var rules: [Rule] = []
        private var byID: [String: Node] = [:]
        /// Each element's parent (clip-rule is inherited from the clipPath's ancestors).
        private var parents: [ObjectIdentifier: Node] = [:]
        private var useDepth = 0

        static let properties: Set<String> = ["fill", "stroke", "stroke-width", "color", "display", "visibility", "opacity",
                                                "fill-opacity", "stroke-opacity", "fill-rule", "clip-rule", "clip-path",
                                                "overflow"]

        init(root: Node, dpi: Double) {
            self.root = root
            self.dpi = dpi
            func visit(_ node: Node) {
                if let id = node["id"], byID[id] == nil { byID[id] = node }
                if node.name == "style" { rules += SVGImport.rules(node.text) }
                for child in node.children {
                    parents[ObjectIdentifier(child)] = node
                    visit(child)
                }
            }
            visit(root)
        }

        mutating func render() {
            // User unit → mm: the SVG's size (width/height) and the viewBox.
            let mmPerPx = 25.4 / dpi
            let box = Self.viewBox(root["viewBox"])
            let width = absoluteLength(root["width"]).map { $0 * mmPerPx } ?? box.map { $0.width * mmPerPx }
            let height = absoluteLength(root["height"]).map { $0 * mmPerPx } ?? box.map { $0.height * mmPerPx }
            var t = CGAffineTransform(scaleX: mmPerPx, y: mmPerPx)
            if let box, box.width > 0, box.height > 0 {
                let l = width ?? box.width * mmPerPx, a = height ?? box.height * mmPerPx
                t = Self.adjustment(box, in: CGSize(width: l, height: a), root["preserveAspectRatio"])
            }
            // The root's viewport doesn't clip: what is off it comes in, as off the page of a PDF.
            render(root, ctm: t, style: ObjectStyle(), clip: nil, svgRoot: true)
        }

        /// viewBox in the area (x, y, width, height), with preserveAspectRatio (default: xMidYMid meet).
        static func adjustment(_ box: CGRect, in area: CGSize, _ aspectRatio: String?, origin: CGPoint = .zero) -> CGAffineTransform {
            let parts = (aspectRatio ?? "xMidYMid meet").split(separator: " ").map(String.init)
            let align = parts.first ?? "xMidYMid"
            var sx = area.width / box.width, sy = area.height / box.height
            if align != "none" {
                let s = parts.contains("slice") ? max(sx, sy) : min(sx, sy)
                sx = s
                sy = s
            }
            func factor(_ axis: String) -> Double { align.contains(axis + "Min") ? 0 : align.contains(axis + "Max") ? 1 : 0.5 }
            let dx = align == "none" ? 0 : (area.width - box.width * sx) * factor("x")
            let dy = align == "none" ? 0 : (area.height - box.height * sy) * factor("Y")
            return CGAffineTransform(translationX: -box.minX, y: -box.minY)
                .concatenating(CGAffineTransform(scaleX: sx, y: sy))
                .concatenating(CGAffineTransform(translationX: origin.x + dx, y: origin.y + dy))
        }

        static func viewBox(_ text: String?) -> CGRect? {
            guard let text else { return nil }
            let v = SVGImport.numbers(text)
            return v.count == 4 ? CGRect(x: v[0], y: v[1], width: v[2], height: v[3]) : nil
        }

        /// Length with an absolute unit, in px (nil without a value or in %).
        func absoluteLength(_ text: String?) -> Double? {
            guard let text, !text.hasSuffix("%") else { return nil }
            return length(text)
        }

        /// Length in user units (px); % of `reference`.
        func length(_ text: String?, reference: Double = 0) -> Double? {
            guard var t = text?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
            var factor = 1.0
            let units: [(String, Double)] = [("px", 1), ("pt", dpi / 72), ("pc", dpi / 6), ("mm", dpi / 25.4), ("cm", dpi / 2.54),
                                                ("in", dpi), ("em", 16), ("ex", 8), ("%", reference / 100)]
            for (suffix, f) in units where t.hasSuffix(suffix) {
                t.removeLast(suffix.count)
                factor = f
                break
            }
            return Double(t.trimmingCharacters(in: .whitespaces)).map { $0 * factor }
        }

        // MARK: Elements

        private mutating func render(_ node: Node, ctm parent: CGAffineTransform, style inherited: ObjectStyle,
                                     clip outer: ImportClipping.Region?, svgRoot: Bool = false) {
            let declared = properties(of: node)
            if declared["display"] == "none" { return }
            if let o = declared["opacity"].flatMap(Double.init), o <= 0 { return }
            let style = apply(declared, a: inherited)
            var ctm = SVGImport.transform(node["transform"]).concatenating(parent)
            // use: x and y move the content and the user space of its clip-path (SVG: a g with translate(x, y)).
            if node.name == "use" { ctm = CGAffineTransform(translationX: length(node["x"]) ?? 0, y: length(node["y"]) ?? 0).concatenating(ctm) }
            var clip = clipping(node, declared, ctm: ctm, inside: outer)
            switch node.name {
            case "svg":
                if !svgRoot {
                    // SVG inside SVG: a new area with its own viewBox, which clips what goes past it (overflow: hidden).
                    let x = length(node["x"]) ?? 0, y = length(node["y"]) ?? 0
                    if let box = Self.viewBox(node["viewBox"]), box.width > 0, box.height > 0 {
                        let area = CGSize(width: length(node["width"]) ?? box.width, height: length(node["height"]) ?? box.height)
                        clip = viewport(CGRect(origin: CGPoint(x: x, y: y), size: area), declared, ctm: ctm, inside: clip)
                        ctm = Self.adjustment(box, in: area, node["preserveAspectRatio"], origin: CGPoint(x: x, y: y)).concatenating(ctm)
                    } else {
                        if let w = absoluteLength(node["width"]), let h = absoluteLength(node["height"]) {
                            clip = viewport(CGRect(x: x, y: y, width: w, height: h), declared, ctm: ctm, inside: clip)
                        }
                        ctm = CGAffineTransform(translationX: x, y: y).concatenating(ctm)
                    }
                }
                for child in node.children { render(child, ctm: ctm, style: style, clip: clip) }
            case "g", "a":
                for child in node.children { render(child, ctm: ctm, style: style, clip: clip) }
            case "switch":
                // The first child that applies: Illustrator's brings a foreignObject of its own first.
                if let child = node.children.first(where: { $0.name != "foreignObject" && $0["requiredExtensions"] == nil }) {
                    render(child, ctm: ctm, style: style, clip: clip)
                }
            case "use":
                guard useDepth < 20, let target = node.href.flatMap({ $0.hasPrefix("#") ? byID[String($0.dropFirst())] : nil })
                else { return }
                useDepth += 1
                defer { useDepth -= 1 }
                if target.name == "symbol" {
                    let symbolProperties = properties(of: target)
                    clip = clipping(target, symbolProperties, ctm: ctm, inside: clip)
                    if let box = Self.viewBox(target["viewBox"]), box.width > 0, box.height > 0 {
                        let area = CGSize(width: length(node["width"]) ?? box.width, height: length(node["height"]) ?? box.height)
                        clip = viewport(CGRect(origin: .zero, size: area), symbolProperties, ctm: ctm, inside: clip)
                        ctm = Self.adjustment(box, in: area, target["preserveAspectRatio"]).concatenating(ctm)
                    }
                    let symbolStyle = apply(symbolProperties, a: style)
                    for child in target.children { render(child, ctm: ctm, style: symbolStyle, clip: clip) }
                } else {
                    render(target, ctm: ctm, style: style, clip: clip)
                }
            case "text":
                result.texts += 1
            case "image":
                result.images += 1
            case "path", "rect", "circle", "ellipse", "line", "polyline", "polygon":
                guard let shape = shape(node) else { return }
                paintPath(shape, ctm: ctm, style: style, clip: clip, withFill: node.name != "line")
            default:
                // defs, symbol, clipPath, mask, pattern, marker, style, metadata, foreignObject… don't draw.
                break
            }
        }

        // MARK: Clipping

        /// The clip for `node` and what it holds: `outer` narrowed by its clip-path. A clip-path that can't be worked out
        /// (it isn't a clipPath, or it holds text, which isn't read) clips nothing, so what it would hide stays.
        private func clipping(_ node: Node, _ declared: [String: String], ctm: CGAffineTransform,
                              inside outer: ImportClipping.Region?, depth: Int = 0) -> ImportClipping.Region? {
            guard depth < 10, let value = declared["clip-path"], let id = Self.reference(value), let clipPath = byID[id],
                  clipPath.name == "clipPath" else { return outer }
            var space = SVGImport.transform(clipPath["transform"]).concatenating(ctm)
            if clipPath["clipPathUnits"] == "objectBoundingBox" {
                // Fractions of the element's box, in its user space; an empty box shows nothing.
                let box = userBox(node)
                guard !box.isNull, box.width > 0, box.height > 0 else { return .nothing }
                space = CGAffineTransform(a: box.width, b: 0, c: 0, d: box.height, tx: box.minX, ty: box.minY).concatenating(space)
            }
            // The region is the union of the children, each with its clip-rule.
            var pieces: [(CGPath, CGPathFillRule)] = []
            for child in clipPath.children {
                let props = properties(of: child)
                if props["display"] == "none" || (props["visibility"].map { $0 != "visible" && $0 != "inherit" } ?? false) { continue }
                var element = child, place = SVGImport.transform(child["transform"]).concatenating(space)
                if child.name == "use" {
                    guard let target = child.href.flatMap({ $0.hasPrefix("#") ? byID[String($0.dropFirst())] : nil }) else { continue }
                    place = SVGImport.transform(target["transform"])
                        .concatenating(CGAffineTransform(translationX: length(child["x"]) ?? 0, y: length(child["y"]) ?? 0))
                        .concatenating(place)
                    element = target
                }
                if element.name == "text" { return outer }
                guard ["path", "rect", "circle", "ellipse", "line", "polyline", "polygon"].contains(element.name),
                      let shape = shape(element), let mm = shape.copy(using: [place]) else { continue }
                // clip-rule: the shape's, the use's, then inherited from the clipPath and its ancestors.
                let rule = Self.rule(properties(of: element)["clip-rule"]) ?? (element === child ? nil : Self.rule(props["clip-rule"]))
                    ?? inheritedClipRule(clipPath) ?? .winding
                pieces.append((mm, rule))
            }
            // A clip-path of the clipPath itself narrows it further.
            let narrowed = clipping(clipPath, properties(of: clipPath), ctm: ctm, inside: outer, depth: depth + 1)
            guard !pieces.isEmpty else { return .nothing }
            if pieces.count == 1 { return ImportClipping.clip(narrowed, to: pieces[0].0, rule: pieces[0].1) }
            var union = pieces[0].0.normalized(using: pieces[0].1)
            for (path, rule) in pieces.dropFirst() { union = union.union(path.normalized(using: rule), using: .evenOdd) }
            return ImportClipping.clip(narrowed, to: union, rule: .evenOdd)
        }

        static func rule(_ value: String?) -> CGPathFillRule? {
            guard let value, value != "inherit" else { return nil }
            return value == "evenodd" ? .evenOdd : .winding
        }

        /// The clip-rule declared on `node` or on its ancestors.
        private func inheritedClipRule(_ node: Node) -> CGPathFillRule? {
            var current: Node? = node
            while let n = current {
                if let rule = Self.rule(properties(of: n)["clip-rule"]) { return rule }
                current = parents[ObjectIdentifier(n)]
            }
            return nil
        }

        /// A nested svg's or a symbol's viewport (user units of `ctm`) clips what it holds, unless overflow is visible.
        private func viewport(_ rect: CGRect, _ declared: [String: String], ctm: CGAffineTransform,
                              inside outer: ImportClipping.Region?) -> ImportClipping.Region? {
            if let overflow = declared["overflow"], overflow == "visible" || overflow == "auto" { return outer }
            guard rect.width > 0, rect.height > 0 else { return outer }
            return ImportClipping.clip(outer, to: CGPath(rect: rect, transform: [ctm]), rule: .winding)
        }

        /// The id in "url(#id)".
        static func reference(_ value: String) -> String? {
            let t = value.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("url(") else { return nil }
            let id = t.dropFirst(4).prefix { $0 != ")" }.trimmingCharacters(in: CharacterSet(charactersIn: " '\"#"))
            return id.isEmpty ? nil : id
        }

        /// The box of what the element draws, in its own user space (for clipPathUnits="objectBoundingBox").
        private func userBox(_ node: Node, depth: Int = 0) -> CGRect {
            guard depth < 20, properties(of: node)["display"] != "none" else { return .null }
            switch node.name {
            case "path", "rect", "circle", "ellipse", "line", "polyline", "polygon":
                return shape(node)?.boundingBoxOfPath ?? .null
            case "g", "a", "switch", "svg":
                return node.children.reduce(CGRect.null) { box, child in
                    let inner = userBox(child, depth: depth + 1)
                    return inner.isNull ? box : box.union(inner.applying(SVGImport.transform(child["transform"])))
                }
            case "use":
                guard let target = node.href.flatMap({ $0.hasPrefix("#") ? byID[String($0.dropFirst())] : nil }) else { return .null }
                let inner = userBox(target, depth: depth + 1)
                return inner.isNull ? inner : inner.applying(SVGImport.transform(target["transform"])
                    .concatenating(CGAffineTransform(translationX: length(node["x"]) ?? 0, y: length(node["y"]) ?? 0)))
            default:
                return .null
            }
        }

        /// The element's outline, in user units.
        private func shape(_ node: Node) -> CGPath? {
            let p = CGMutablePath()
            func n(_ key: String, _ reference: Double = 0) -> Double { length(node[key], reference: reference) ?? 0 }
            switch node.name {
            case "path":
                SVGImport.shapePath(node["d"] ?? "", in: p)
            case "rect":
                let r = CGRect(x: n("x"), y: n("y"), width: n("width"), height: n("height"))
                guard r.width > 0, r.height > 0 else { return nil }
                var rx = length(node["rx"]), ry = length(node["ry"])
                if rx == nil { rx = ry }
                if ry == nil { ry = rx }
                let cx = min(max(rx ?? 0, 0), r.width / 2), cy = min(max(ry ?? 0, 0), r.height / 2)
                if cx > 0, cy > 0 { p.addRoundedRect(in: r, cornerWidth: cx, cornerHeight: cy) } else { p.addRect(r) }
            case "circle":
                let r = n("r")
                guard r > 0 else { return nil }
                p.addEllipse(in: CGRect(x: n("cx") - r, y: n("cy") - r, width: 2 * r, height: 2 * r))
            case "ellipse":
                var rx = length(node["rx"]), ry = length(node["ry"])
                if rx == nil { rx = ry }
                if ry == nil { ry = rx }
                guard let rx, let ry, rx > 0, ry > 0 else { return nil }
                p.addEllipse(in: CGRect(x: n("cx") - rx, y: n("cy") - ry, width: 2 * rx, height: 2 * ry))
            case "line":
                p.move(to: CGPoint(x: n("x1"), y: n("y1")))
                p.addLine(to: CGPoint(x: n("x2"), y: n("y2")))
            default:   // polyline, polygon
                let v = SVGImport.numbers(node["points"] ?? "")
                guard v.count >= 4 else { return nil }
                p.move(to: CGPoint(x: v[0], y: v[1]))
                for i in stride(from: 2, to: v.count - 1, by: 2) { p.addLine(to: CGPoint(x: v[i], y: v[i + 1])) }
                if node.name == "polygon" { p.closeSubpath() }
            }
            return p.isEmpty ? nil : p
        }

        private mutating func paintPath(_ shape: CGPath, ctm: CGAffineTransform, style: ObjectStyle, clip: ImportClipping.Region?,
                                        withFill: Bool) {
            guard style.visible, let mm = shape.copy(using: [ctm]) else { return }
            let fill = withFill && style.fillOpacity > 0 ? color(style.fill, style) : nil
            let strokeColor = style.strokeWidth > 0 && style.strokeOpacity > 0 ? color(style.stroke, style) : nil
            // Width in pt at the page's scale.
            let scale = sqrt(abs(ctm.a * ctm.d - ctm.b * ctm.c))
            result.objects += ImportClipping.objects(mm, strokeColor: strokeColor, strokeWidth: style.strokeWidth * scale * 72 / 25.4,
                                                     fill: fill, evenOdd: style.evenOdd, clip: clip)
        }

        private func color(_ paint: Paint, _ style: ObjectStyle) -> CMYK? {
            switch paint {
            case .noneSelected: nil
            case .color(let c): c
            case .current: style.color
            case .url(let id): gradientColor(id)
            }
        }

        /// Average of the gradient stops' colors (following the href); default, middle gray.
        private func gradientColor(_ id: String) -> CMYK? {
            var node = byID[id], turns = 0
            while let current = node, current.children.allSatisfy({ $0.name != "stop" }), let href = current.href, turns < 10 {
                node = byID[String(href.drop(while: { $0 == "#" }))]
                turns += 1
            }
            guard let node else { return nil }
            guard node.name == "linearGradient" || node.name == "radialGradient" else { return CMYK(c: 0, m: 0, y: 0, k: 50) }
            let colors = node.children.filter { $0.name == "stop" }.compactMap { stopped -> (Double, Double, Double)? in
                let props = properties(of: stopped, extras: ["stop-color"])
                guard let text = props["stop-color"], let rgb = SVGImport.rgb(text) else { return (0, 0, 0) }
                return rgb
            }
            guard !colors.isEmpty else { return nil }
            let n = Double(colors.count)
            return VectorImporter.rgb(colors.map(\.0).reduce(0, +) / n, colors.map(\.1).reduce(0, +) / n,
                                         colors.map(\.2).reduce(0, +) / n)
        }

        /// Properties declared on the element: attributes < CSS < style=.
        private func properties(of node: Node, extras: Set<String> = []) -> [String: String] {
            let names = Self.properties.union(extras)
            var p: [String: String] = [:]
            for (key, value) in node.attributes where names.contains(key) { p[key] = value.trimmingCharacters(in: .whitespaces) }
            for rule in rules where rule.valley(to: node) {
                for (key, value) in rule.declarations where names.contains(key) { p[key] = value }
            }
            if let style = node["style"] {
                for (key, value) in SVGImport.declarations(style) where names.contains(key) { p[key] = value }
            }
            return p
        }

        private func apply(_ p: [String: String], a inherited: ObjectStyle) -> ObjectStyle {
            var e = inherited
            func paint(_ text: String) -> Paint? {
                let t = text.trimmingCharacters(in: .whitespaces)
                if t == "none" || t == "transparent" { return Paint.noneSelected }
                if t.lowercased() == "currentcolor" { return .current }
                if t.hasPrefix("url(") {
                    let inside = t.dropFirst(4).prefix { $0 != ")" }.trimmingCharacters(in: CharacterSet(charactersIn: " '\"#"))
                    return .url(inside)
                }
                guard let rgb = SVGImport.rgb(t) else { return nil }
                if SVGImport.transparent(t) { return Paint.noneSelected }
                return .color(VectorImporter.rgb(rgb.0, rgb.1, rgb.2))
            }
            if let v = p["color"], let rgb = SVGImport.rgb(v) { e.color = VectorImporter.rgb(rgb.0, rgb.1, rgb.2) }
            if let v = p["fill"], v != "inherit", let newOne = paint(v) { e.fill = newOne }
            if let v = p["stroke"], v != "inherit", let newOne = paint(v) { e.stroke = newOne }
            if let v = p["stroke-width"], v != "inherit", let w = length(v) { e.strokeWidth = max(w, 0) }
            if let v = p["visibility"] { e.visible = v == "inherit" ? inherited.visible : v == "visible" }
            if let v = p["fill-opacity"].flatMap(Double.init) { e.fillOpacity = v }
            if let v = p["stroke-opacity"].flatMap(Double.init) { e.strokeOpacity = v }
            if let v = p["fill-rule"], v != "inherit" { e.evenOdd = v == "evenodd" }
            return e
        }
    }

    // MARK: Values

    /// Numbers from a list (spaces or commas; "1.5.5" is two numbers, "-1-2" too).
    static func numbers(_ text: String) -> [Double] {
        var reader = NumberReader(Array(text.utf8))
        var v: [Double] = []
        while let n = reader.number() { v.append(n) }
        return v
    }

    nonisolated struct NumberReader {
        let b: [UInt8]
        var i = 0

        init(_ b: [UInt8]) { self.b = b }

        mutating func skipSeparators() {
            while i < b.count, b[i] == 32 || b[i] == 9 || b[i] == 10 || b[i] == 13 || b[i] == 44 { i += 1 }
        }

        mutating func number() -> Double? {
            skipSeparators()
            let start = i
            if i < b.count, b[i] == 43 || b[i] == 45 { i += 1 }
            var digits = false, point = false
            while i < b.count {
                let c = b[i]
                if c >= 48 && c <= 57 { digits = true; i += 1 } else if c == 46 && !point { point = true; i += 1 } else { break }
            }
            guard digits else { i = start; return nil }
            if i < b.count, b[i] == 101 || b[i] == 69 {
                var j = i + 1
                if j < b.count, b[j] == 43 || b[j] == 45 { j += 1 }
                if j < b.count, b[j] >= 48 && b[j] <= 57 {
                    while j < b.count, b[j] >= 48 && b[j] <= 57 { j += 1 }
                    i = j
                }
            }
            return Double(String(decoding: b[start..<i], as: UTF8.self)).flatMap { $0.isFinite ? $0 : nil }
        }

        /// Arc flag: a single character, even without a separator ("a1 1 0 01 10 10").
        mutating func flag() -> Bool? {
            skipSeparators()
            guard i < b.count, b[i] == 48 || b[i] == 49 else { return nil }
            i += 1
            return b[i - 1] == 49
        }

        mutating func command() -> UInt8? {
            skipSeparators()
            guard i < b.count else { return nil }
            let c = b[i]
            if (c >= 65 && c <= 90) || (c >= 97 && c <= 122), c != 101, c != 69 {
                i += 1
                return c
            }
            return nil
        }

        var end: Bool {
            mutating get {
                skipSeparators()
                return i >= b.count
            }
        }
    }

    /// List of SVG transforms ("translate(10) rotate(45 5 5) …"), applied right to left.
    static func transform(_ text: String?) -> CGAffineTransform {
        guard let text, !text.isEmpty else { return .identity }
        var total = CGAffineTransform.identity
        var rest = Substring(text)
        while let opens = rest.firstIndex(of: "("), let closes = rest[opens...].firstIndex(of: ")") {
            let name = rest[..<opens].trimmingCharacters(in: CharacterSet(charactersIn: " ,\t\n\r")).lowercased()
            let v = numbers(String(rest[rest.index(after: opens)..<closes]))
            rest = rest[rest.index(after: closes)...]
            func a(_ i: Int, _ defaultValue: Double = 0) -> Double { i < v.count ? v[i] : defaultValue }
            let t: CGAffineTransform
            switch name {
            case "matrix" where v.count == 6: t = CGAffineTransform(a: v[0], b: v[1], c: v[2], d: v[3], tx: v[4], ty: v[5])
            case "translate": t = CGAffineTransform(translationX: a(0), y: a(1))
            case "scale": t = CGAffineTransform(scaleX: a(0, 1), y: a(1, a(0, 1)))
            case "rotate":
                let spin = CGAffineTransform(rotationAngle: a(0) * .pi / 180)
                t = v.count >= 3
                    ? CGAffineTransform(translationX: -v[1], y: -v[2]).concatenating(spin).concatenating(CGAffineTransform(translationX: v[1], y: v[2]))
                    : spin
            case "skewx": t = CGAffineTransform(a: 1, b: 0, c: tan(a(0) * .pi / 180), d: 1, tx: 0, ty: 0)
            case "skewy": t = CGAffineTransform(a: 1, b: tan(a(0) * .pi / 180), c: 0, d: 1, tx: 0, ty: 0)
            default: t = .identity
            }
            // "A B" = A(B(p)): B applies first.
            total = t.concatenating(total)
        }
        return total
    }

    /// RGB from 0 to 1 of a CSS color (#rgb, #rrggbb, #rrggbbaa, rgb(), rgba(), hsl() and names); nil if it isn't a color.
    static func rgb(_ text: String) -> (Double, Double, Double)? {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        if t.hasPrefix("#") {
            let h = Array(t.dropFirst())
            func hex(_ s: [Character]) -> Double? { Int(String(s), radix: 16).map { Double($0) / (s.count == 1 ? 15 : 255) } }
            switch h.count {
            case 3, 4: if let r = hex([h[0]]), let g = hex([h[1]]), let b = hex([h[2]]) { return (r, g, b) }
            case 6, 8: if let r = hex(Array(h[0..<2])), let g = hex(Array(h[2..<4])), let b = hex(Array(h[4..<6])) { return (r, g, b) }
            default: break
            }
            return nil
        }
        if t.hasPrefix("rgb") || t.hasPrefix("hsl") {
            guard let opens = t.firstIndex(of: "(") else { return nil }
            let parts = t[t.index(after: opens)...].prefix { $0 != ")" }
                .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" }).map(String.init)
            guard parts.count >= 3 else { return nil }
            if t.hasPrefix("rgb") {
                func channel(_ s: String) -> Double {
                    s.hasSuffix("%") ? (Double(s.dropLast()) ?? 0) / 100 : (Double(s) ?? 0) / 255
                }
                return (channel(parts[0]), channel(parts[1]), channel(parts[2]))
            }
            let h = (Double(parts[0].replacingOccurrences(of: "deg", with: "")) ?? 0) / 360
            let s = (Double(parts[1].replacingOccurrences(of: "%", with: "")) ?? 0) / 100
            let l = (Double(parts[2].replacingOccurrences(of: "%", with: "")) ?? 0) / 100
            let q = l < 0.5 ? l * (1 + s) : l + s - l * s, p = 2 * l - q
            func f(_ x: Double) -> Double {
                let t = x < 0 ? x + 1 : x > 1 ? x - 1 : x
                return t < 1 / 6 ? p + (q - p) * 6 * t : t < 1 / 2 ? q : t < 2 / 3 ? p + (q - p) * (2 / 3 - t) * 6 : p
            }
            return (f(h + 1 / 3), f(h), f(h - 1 / 3))
        }
        return names[t].map { (Double(($0 >> 16) & 255) / 255, Double(($0 >> 8) & 255) / 255, Double($0 & 255) / 255) }
    }

    /// Color with zero alpha (#rgba, #rrggbbaa, rgba(…, 0)).
    static func transparent(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        if t.hasPrefix("#") { return (t.count == 5 && t.hasSuffix("0")) || (t.count == 9 && t.hasSuffix("00")) }
        if t.hasPrefix("rgba") || t.hasPrefix("hsla") || t.contains("/") {
            let parts = t.prefix { $0 != ")" }.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "/" || $0 == "(" })
            if parts.count >= 5, let alfa = Double(parts[4].replacingOccurrences(of: "%", with: "")) { return alfa == 0 }
        }
        return false
    }

    /// Most common CSS color names.
    static let names: [String: Int] = [
        "black": 0x000000, "white": 0xFFFFFF, "red": 0xFF0000, "green": 0x008000, "blue": 0x0000FF, "yellow": 0xFFFF00,
        "cyan": 0x00FFFF, "aqua": 0x00FFFF, "magenta": 0xFF00FF, "fuchsia": 0xFF00FF, "gray": 0x808080, "grey": 0x808080,
        "silver": 0xC0C0C0, "maroon": 0x800000, "olive": 0x808000, "lime": 0x00FF00, "teal": 0x008080, "navy": 0x000080,
        "purple": 0x800080, "orange": 0xFFA500, "pink": 0xFFC0CB, "brown": 0xA52A2A, "gold": 0xFFD700, "beige": 0xF5F5DC,
        "coral": 0xFF7F50, "crimson": 0xDC143C, "darkblue": 0x00008B, "darkgreen": 0x006400, "darkred": 0x8B0000,
        "darkgray": 0xA9A9A9, "darkgrey": 0xA9A9A9, "lightgray": 0xD3D3D3, "lightgrey": 0xD3D3D3, "dimgray": 0x696969,
        "indigo": 0x4B0082, "violet": 0xEE82EE, "khaki": 0xF0E68C, "salmon": 0xFA8072, "tomato": 0xFF6347,
        "turquoise": 0x40E0D0, "tan": 0xD2B48C, "orchid": 0xDA70D6, "plum": 0xDDA0DD, "skyblue": 0x87CEEB,
        "steelblue": 0x4682B4, "royalblue": 0x4169E1, "seagreen": 0x2E8B57, "forestgreen": 0x228B22, "chocolate": 0xD2691E,
        "firebrick": 0xB22222, "darkorange": 0xFF8C00, "hotpink": 0xFF69B4, "deeppink": 0xFF1493, "lightblue": 0xADD8E6,
        "lightgreen": 0x90EE90, "whitesmoke": 0xF5F5F5, "ivory": 0xFFFFF0, "lavender": 0xE6E6FA, "slategray": 0x708090,
    ]

    // MARK: Path (d attribute)

    /// Appends the path from the `d` attribute (user units).
    static func shapePath(_ d: String, in p: CGMutablePath) {
        var l = NumberReader(Array(d.utf8))
        var current = CGPoint.zero, start = CGPoint.zero
        var control: CGPoint?, controlKind: UInt8 = 0
        var command: UInt8 = 0
        var needsMove = true
        func ensure() {
            if needsMove { p.move(to: current); start = current; needsMove = false }
        }
        while !l.end {
            if let c = l.command() { command = c } else if command == 0 { break }
            let relative = command >= 97
            let base = relative ? current : .zero
            func point() -> CGPoint? {
                guard let x = l.number(), let y = l.number() else { return nil }
                return CGPoint(x: base.x + x, y: base.y + y)
            }
            var previous = controlKind
            controlKind = 0
            switch command | 0x20 {   // lowercase
            case 109:   // m
                guard let q = point() else { return }
                p.move(to: q)
                current = q
                start = q
                needsMove = false
                // Pairs after the M are lines.
                command = relative ? 108 : 76
                previous = 0
            case 122:   // z
                if !p.isEmpty, !needsMove { p.closeSubpath() }
                current = start
                needsMove = true
                command = 0
            case 108:   // l
                guard let q = point() else { return }
                ensure()
                p.addLine(to: q)
                current = q
            case 104:   // h
                guard let x = l.number() else { return }
                ensure()
                current = CGPoint(x: relative ? current.x + x : x, y: current.y)
                p.addLine(to: current)
            case 118:   // v
                guard let y = l.number() else { return }
                ensure()
                current = CGPoint(x: current.x, y: relative ? current.y + y : y)
                p.addLine(to: current)
            case 99:   // c
                guard let c1 = point(), let c2 = point(), let q = point() else { return }
                ensure()
                p.addCurve(to: q, control1: c1, control2: c2)
                (current, control, controlKind) = (q, c2, 99)
            case 115:   // s
                guard let c2 = point(), let q = point() else { return }
                ensure()
                let c1 = previous == 99 ? CGPoint(x: 2 * current.x - control!.x, y: 2 * current.y - control!.y) : current
                p.addCurve(to: q, control1: c1, control2: c2)
                (current, control, controlKind) = (q, c2, 99)
            case 113:   // q
                guard let c1 = point(), let q = point() else { return }
                ensure()
                p.addQuadCurve(to: q, control: c1)
                (current, control, controlKind) = (q, c1, 113)
            case 116:   // t
                guard let q = point() else { return }
                ensure()
                let c1 = previous == 113 ? CGPoint(x: 2 * current.x - control!.x, y: 2 * current.y - control!.y) : current
                p.addQuadCurve(to: q, control: c1)
                (current, control, controlKind) = (q, c1, 113)
            case 97:   // a
                guard let rx = l.number(), let ry = l.number(), let spin = l.number(), let large = l.flag(),
                      let clockwise = l.flag(), let q = point() else { return }
                ensure()
                arc(in: p, of: current, until: q, rx: rx, ry: ry, spin: spin, large: large, clockwise: clockwise)
                current = q
            default:
                return
            }
        }
    }

    /// SVG elliptical arc (point to point) as cubics of up to 90°.
    static func arc(in p: CGMutablePath, of a: CGPoint, until b: CGPoint, rx: Double, ry: Double, spin: Double, large: Bool, clockwise: Bool) {
        var rx = abs(rx), ry = abs(ry)
        guard rx > 0, ry > 0, a != b else { p.addLine(to: b); return }
        let phi = spin * .pi / 180, cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (a.x - b.x) / 2, dy = (a.y - b.y) / 2
        let x1 = cosPhi * dx + sinPhi * dy, y1 = -sinPhi * dx + cosPhi * dy
        let lambda = x1 * x1 / (rx * rx) + y1 * y1 / (ry * ry)
        if lambda > 1 { rx *= sqrt(lambda); ry *= sqrt(lambda) }
        let num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1
        let den = rx * rx * y1 * y1 + ry * ry * x1 * x1
        var coef = den > 0 ? sqrt(max(num / den, 0)) : 0
        if large == clockwise { coef = -coef }
        let cxl = coef * rx * y1 / ry, cyl = -coef * ry * x1 / rx
        let cx = cosPhi * cxl - sinPhi * cyl + (a.x + b.x) / 2, cy = sinPhi * cxl + cosPhi * cyl + (a.y + b.y) / 2
        func angle(_ ux: Double, _ uy: Double, _ vx: Double, _ vy: Double) -> Double {
            let s = ux * vy - uy * vx >= 0 ? 1.0 : -1.0
            let d = (ux * vx + uy * vy) / (hypot(ux, uy) * hypot(vx, vy))
            return s * acos(min(max(d, -1), 1))
        }
        let t1 = angle(1, 0, (x1 - cxl) / rx, (y1 - cyl) / ry)
        var dt = angle((x1 - cxl) / rx, (y1 - cyl) / ry, (-x1 - cxl) / rx, (-y1 - cyl) / ry)
        if !clockwise, dt > 0 { dt -= 2 * .pi } else if clockwise, dt < 0 { dt += 2 * .pi }
        let parts = max(1, Int(ceil(abs(dt) / (.pi / 2) - 1e-9)))
        let step = dt / Double(parts)
        let k = 4.0 / 3 * tan(step / 4)
        func point(_ t: Double) -> CGPoint {
            CGPoint(x: cx + rx * cos(t) * cosPhi - ry * sin(t) * sinPhi, y: cy + rx * cos(t) * sinPhi + ry * sin(t) * cosPhi)
        }
        func derivative(_ t: Double) -> CGPoint {
            CGPoint(x: -rx * sin(t) * cosPhi - ry * cos(t) * sinPhi, y: -rx * sin(t) * sinPhi + ry * cos(t) * cosPhi)
        }
        var t = t1
        for i in 0..<parts {
            let t2 = t + step
            let p1 = point(t), p2 = i == parts - 1 ? b : point(t2), d1 = derivative(t), d2 = derivative(t2)
            p.addCurve(to: p2, control1: CGPoint(x: p1.x + k * d1.x, y: p1.y + k * d1.y),
                       control2: CGPoint(x: p2.x - k * d2.x, y: p2.y - k * d2.y))
            t = t2
        }
    }
}
