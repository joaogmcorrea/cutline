// Pathfinder (as in Illustrator and in the prototype): boolean operations between the selected objects,
// with CoreGraphics' own (macOS 14+). The result becomes a free path and inherits the style.
import CoreGraphics
import SwiftUI

nonisolated enum PathfinderOperation: String, CaseIterable, Identifiable, Sendable {
    case unite, minusFront, intersect, exclude, divide, minusBack

    var id: Self { self }

    var name: String {
        switch self {
        case .unite: String(localized: "Unite")
        case .minusFront: String(localized: "Minus Front")
        case .intersect: String(localized: "Intersect")
        case .exclude: String(localized: "Exclude Overlap")
        case .divide: String(localized: "Divide")
        case .minusBack: String(localized: "Minus Back")
        }
    }

    /// Name of the objects that come out of the operation.
    var result: String {
        switch self {
        case .unite: String(localized: "Union")
        case .minusFront, .minusBack: String(localized: "Subtraction")
        case .intersect: String(localized: "Intersect", comment: "Name of the object that comes out of the Pathfinder")
        case .exclude: String(localized: "Exclusion")
        case .divide: String(localized: "Piece")
        }
    }

    /// The first four are "shape modes"; the last two, "pathfinders".
    var isShapeMode: Bool { self != .divide && self != .minusBack }
}

extension CanvasObject {
    /// Free path from an outline in page mm: the frame is the outline's box.
    nonisolated static func freePath(_ path: CGPath) -> (frame: CGRect, subpaths: [Subpath])? {
        let box = path.boundingBoxOfPath
        guard !box.isNull, !box.isInfinite else { return nil }
        let width = box.width > 0 ? box.width : 1, height = box.height > 0 ? box.height : 1
        let relative = { (p: CGPoint) in CGPoint(x: (p.x - box.minX) / width, y: (p.y - box.minY) / height) }
        var subpaths: [Subpath] = []
        var current: [Node] = []
        func close(_ closed: Bool) {
            var nodes = current
            // The closing usually repeats the first point: merge the two.
            if closed, nodes.count > 1, let first = nodes.first, let lastOne = nodes.last,
               hypot(first.point.x - lastOne.point.x, first.point.y - lastOne.point.y) < 1e-6 {
                nodes[0].input = lastOne.input
                nodes.removeLast()
            }
            if nodes.count > 1 {
                subpaths.append(Subpath(nodes: nodes.map { Node(point: relative($0.point), input: $0.input.map(relative),
                                                                output: $0.output.map(relative)) }, closed: closed))
            }
            current = []
        }
        path.applyWithBlock { element in
            let e = element.pointee
            switch e.type {
            case .moveToPoint:
                if !current.isEmpty { close(false) }
                current = [Node(point: e.points[0])]
            case .addLineToPoint:
                current.append(Node(point: e.points[0]))
            case .addQuadCurveToPoint:
                guard let previous = current.last?.point else { return }
                let q = e.points[0], p = e.points[1]
                current[current.count - 1].output = CGPoint(x: previous.x + 2 / 3 * (q.x - previous.x), y: previous.y + 2 / 3 * (q.y - previous.y))
                current.append(Node(point: p, input: CGPoint(x: p.x + 2 / 3 * (q.x - p.x), y: p.y + 2 / 3 * (q.y - p.y))))
            case .addCurveToPoint:
                guard !current.isEmpty else { return }
                current[current.count - 1].output = e.points[0]
                current.append(Node(point: e.points[2], input: e.points[1]))
            case .closeSubpath:
                close(true)
            @unknown default:
                break
            }
        }
        if !current.isEmpty { close(false) }
        return subpaths.isEmpty ? nil : (box, subpaths)
    }
}

extension Document {
    /// Applies the operation to the selected objects; returns a notice when it can't.
    func pathfinder(_ operation: PathfinderOperation) -> String? {
        let objs = objectsInOrder.filter { selection.contains($0.id) }   // back to front
        guard objs.count >= 2 else { return String(localized: "Select at least two objects for Pathfinder.") }
        guard objs.allSatisfy({ $0.image == nil }) else { return String(localized: "Images can’t be used in Pathfinder.") }
        let rule = CGPathFillRule.evenOdd
        let p = objs.map { $0.shapePath.cgPath }
        var pieces: [(CGPath, CanvasObject)]
        switch operation {
        case .unite:
            pieces = [(p.dropFirst().reduce(p[0]) { $0.union($1, using: rule) }, objs.last!)]
        case .intersect:
            pieces = [(p.dropFirst().reduce(p[0]) { $0.intersection($1, using: rule) }, objs.last!)]
        case .exclude:
            pieces = [(p.dropFirst().reduce(p[0]) { $0.symmetricDifference($1, using: rule) }, objs.last!)]
        case .minusFront:
            pieces = [(p.dropFirst().reduce(p[0]) { $0.subtracting($1, using: rule) }, objs[0])]
        case .minusBack:
            pieces = [(p.dropLast().reduce(p[p.count - 1]) { $0.subtracting($1, using: rule) }, objs.last!)]
        case .divide:
            // Each new shape cuts the pieces that already exist; each region becomes an object.
            var parts: [(CGPath, CanvasObject)] = [(p[0], objs[0])]
            for i in 1..<p.count {
                var newOnes: [(CGPath, CanvasObject)] = []
                var rest = p[i]
                for (piece, of) in parts {
                    newOnes.append((piece.intersection(p[i], using: rule), objs[i]))
                    newOnes.append((piece.subtracting(p[i], using: rule), of))
                    rest = rest.subtracting(piece, using: rule)
                }
                newOnes.append((rest, objs[i]))
                parts = newOnes
            }
            pieces = parts.flatMap { shapePath, of in shapePath.componentsSeparated(using: rule).map { ($0, of) } }
        }
        let newItems: [CanvasObject] = pieces.compactMap { shapePath, of in
            let box = shapePath.boundingBoxOfPath
            guard !shapePath.isEmpty, box.width * box.height > 0.0001, let free = CanvasObject.freePath(shapePath) else { return nil }
            var object = of
            object.id = UUID()
            object.shape = .shapePath(free.subpaths)
            object.frame = free.frame
            object.label = operation.result
            return object
        }
        guard !newItems.isEmpty else { return String(localized: "The result is empty — do the shapes overlap?") }
        registrar()
        let position = (objects.indices.filter { selection.contains(objects[$0].id) }.max() ?? objects.count - 1) + 1
        objects.insert(contentsOf: newItems, at: min(position, objects.count))
        objects.removeAll { selection.contains($0.id) }
        selection = Set(newItems.map(\.id))
        return nil
    }
}
