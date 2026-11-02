// Print & Cut: when the machine doesn't find the marks, a window over Send with the animated illustration
// (sheet pushed into the mat's corner and the sensor looking for the three marks), the most common mistakes and the
// shortcut to try reading again.
import SwiftUI

struct MarksWindow: View {
    let job: Job
    @Environment(Machine.self) private var machine
    @Environment(\.dismiss) private var close

    private struct Tip: Identifiable {
        let icon: ImageResource
        let title: String
        let text: String
        var id: String { title }
    }

    private var tips: [Tip] {
        [Tip(icon: .sheetCorner, title: String(localized: "Sheet in the corner, straight"),
              text: job.withMat
                ? String(localized: "Place it in the top-left corner of the mat’s grid, with the black square at the top left — it goes into the machine first.")
                : String(localized: "Push the sheet straight against the left guide, with the black square at the top left — it goes into the machine first.")),
         Tip(icon: .printer, title: String(localized: "Printed at 100%"),
              text: String(localized: "No “scale to fit”. The square should be 15 mm from the edges of the sheet — you can check it with a ruler.")),
         Tip(icon: .contrast, title: String(localized: "Deep black marks"),
              text: String(localized: "No draft or ink-saving mode. Glossy or laminated paper reflects the light and hides the marks.")),
         Tip(icon: .lightbulb, title: String(localized: "Light and clear area"),
              text: String(localized: "Strong light on the machine (sun, lamps) confuses the sensor. Nothing printed near the marks (the hatched area on screen)."))]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 28) {
                MarksAnimation(withMat: job.withMat)
                    .frame(width: 290)
                VStack(alignment: .leading, spacing: 16) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("The machine couldn’t find the marks")
                            .font(.title2.weight(.semibold))
                        Text("Nothing was cut. If you need to adjust the sheet, unload the mat, fix it and load it again.")
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(tips) { tip in
                        HStack(alignment: .top, spacing: 12) {
                            Image(tip.icon)
                                .resizable()
                                .frame(width: 18, height: 18)
                                .foregroundStyle(.tint)
                                .frame(width: 30, height: 30)
                                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tip.title).fontWeight(.semibold)
                                Text(tip.text)
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            .padding(28)
            HStack(spacing: 12) {
                Button("Remove from Queue") {
                    machine.removeItem(job.id)
                    close()
                }
                Spacer()
                Button("Close") { close() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    machine.retry(job.id)
                    close()
                } label: {
                    Label("Try Reading Again", image: .refresh)
                        .padding(.horizontal, 6)
                }
                .buttonStyle(.glassProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(.bar)
            .overlay(alignment: .top) { Divider() }
        }
        .frame(width: 780)
    }
}

/// The sheet goes into the mat's corner (without a mat: against the guide) and the machine's sensor passes over the square and the
/// two corner marks, which light up when found. In an 8 s loop.
struct MarksAnimation: View {
    let withMat: Bool
    @State private var start = Date()

    private static let cycle = 8.0

    var body: some View {
        TimelineView(.animation) { cgContext in
            let t = cgContext.date.timeIntervalSince(start).truncatingRemainder(dividingBy: Self.cycle)
            VStack(spacing: 12) {
                Canvas { ctx, size in render(&ctx, size: size, t: t) }
                    .frame(width: 290, height: 290 * 262 / 300)
                Text(caption(t))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(height: 38, alignment: .top)
                    .contentTransition(.opacity)
                    .animation(.easeInOut(duration: 0.3), value: caption(t))
            }
        }
    }

    private func caption(_ t: Double) -> String {
        if t < 2.4 {
            return withMat ? String(localized: "Place the sheet in the top-left corner of the mat, nice and straight.")
                : String(localized: "Push the sheet against the left guide, nice and straight.")
        }
        if t < 6.6 { return String(localized: "The machine looks for the square and the two corner marks…") }
        return String(localized: "Found all three marks: now it cuts right over the print.")
    }

    // MARK: Drawing (units of 300 × 262)

    private static let base = CGRect(x: 72, y: 46, width: 156, height: 214)
    private static let sheet = CGSize(width: 148, height: 206)
    /// Marks larger than the real ones, so they show in the illustration.
    private static let indentation = 12.0, square = 10.0, cornerMark = 24.0, strokeWidth = 2.6

    private func render(_ ctx: inout GraphicsContext, size: CGSize, t: Double) {
        let e = min(size.width / 300, size.height / 262)
        ctx.scaleBy(x: e, y: e)
        let base = Self.base
        let sheetOrigin = CGPoint(x: base.minX + 4, y: base.minY + 4)

        // Cutting mat (plastic with a grid) or just the machine's guide.
        if withMat {
            ctx.fill(Path(roundedRect: base, cornerRadius: 5), with: .color(Color(red: 0.62, green: 0.76, blue: 0.9).opacity(0.55)))
            var grade = Path()
            var x = base.minX + 4
            while x <= base.maxX - 4 { grade.move(to: CGPoint(x: x, y: base.minY + 4)); grade.addLine(to: CGPoint(x: x, y: base.maxY - 4)); x += 18.4 }
            var y = base.minY + 4
            while y <= base.maxY - 4 { grade.move(to: CGPoint(x: base.minX + 4, y: y)); grade.addLine(to: CGPoint(x: base.maxX - 4, y: y)); y += 18.4 }
            ctx.stroke(grade, with: .color(Color(red: 0.25, green: 0.45, blue: 0.7).opacity(0.35)), lineWidth: 0.6)
        } else {
            var guide = Path()
            guide.move(to: CGPoint(x: sheetOrigin.x - 3, y: base.minY))
            guide.addLine(to: CGPoint(x: sheetOrigin.x - 3, y: base.maxY))
            ctx.stroke(guide, with: .color(.secondary), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
        }

        // Sheet arriving at the corner: skewed and offset → snapped in place.
        let arrival = Self.easeInOut((t - 0.2) / 1.6)
        let offset = CGSize(width: 18 * (1 - arrival), height: 26 * (1 - arrival))
        let spin = Angle.degrees(6 * (1 - arrival))
        var sheet = ctx
        sheet.translateBy(x: sheetOrigin.x + offset.width, y: sheetOrigin.y + offset.height)
        sheet.rotate(by: spin)
        let box = CGRect(origin: .zero, size: Self.sheet)
        var shadow = sheet
        shadow.addFilter(.shadow(color: .black.opacity(0.18), radius: 3, y: 1.5))
        shadow.fill(Path(box), with: .color(.white))
        // Printed artwork with the cut contour on top.
        let sticker = CGRect(x: 34, y: 52, width: 62, height: 46)
        sheet.fill(Path(roundedRect: sticker, cornerRadius: 10), with: .color(Color(red: 0.98, green: 0.55, blue: 0.62)))
        sheet.stroke(Path(roundedRect: sticker.insetBy(dx: -4, dy: -4), cornerRadius: 13), with: .color(.red), style: StrokeStyle(lineWidth: 0.9, dash: [3, 2]))
        let circle = CGRect(x: 72, y: 118, width: 44, height: 44)
        sheet.fill(Path(ellipseIn: circle), with: .color(Color(red: 0.99, green: 0.82, blue: 0.3)))
        sheet.stroke(Path(ellipseIn: circle.insetBy(dx: -4, dy: -4)), with: .color(.red), style: StrokeStyle(lineWidth: 0.9, dash: [3, 2]))
        for rectangle in Self.marks { sheet.fill(Path(rectangle), with: .color(.black)) }

        // Mat corner highlighted while the sheet moves in; green once it's in place.
        if t < 2.6 {
            let didSnap = t > 1.8
            var join = Path()
            join.move(to: CGPoint(x: sheetOrigin.x - 3, y: sheetOrigin.y + 34))
            join.addLine(to: CGPoint(x: sheetOrigin.x - 3, y: sheetOrigin.y - 3))
            join.addLine(to: CGPoint(x: sheetOrigin.x + 34, y: sheetOrigin.y - 3))
            let pulse = 0.55 + 0.45 * sin(t * 6)
            ctx.stroke(join, with: .color((didSnap ? Color.green : .accentColor).opacity(didSnap ? 1 : pulse)),
                       style: StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
        }

        // Sensor: passes over the three marks; each lights up when found.
        let targets = Self.targets.map { CGPoint(x: $0.x + sheetOrigin.x, y: $0.y + sheetOrigin.y) }
        let home = CGPoint(x: 236, y: 40)
        let textRuns: [(start: Double, end: Double, of: CGPoint, to: CGPoint)] = [
            (2.4, 3.2, home, targets[0]), (3.7, 4.5, targets[0], targets[1]), (5.0, 6.1, targets[1], targets[2]),
        ]
        let didFind = [3.2, 4.5, 6.1].map { t >= $0 }
        var sensor: CGPoint? = nil
        if t >= 2.4, t < 7.6 {
            sensor = targets[2]
            for run in textRuns where t < run.end {
                let p = t < run.start ? 0 : Self.easeInOut((t - run.start) / (run.end - run.start))
                sensor = CGPoint(x: run.of.x + (run.to.x - run.of.x) * p, y: run.of.y + (run.to.y - run.of.y) * p)
                break
            }
        }
        for (i, target) in targets.enumerated() where didFind[i] && t < 7.6 {
            let ring = Path(ellipseIn: CGRect(x: target.x - 11, y: target.y - 11, width: 22, height: 22))
            ctx.fill(ring, with: .color(.green.opacity(0.18)))
            ctx.stroke(ring, with: .color(.green), lineWidth: 1.6)
        }

        // Machine on top (the sheet goes in under it), with the carriage that carries the sensor.
        let pointSize = CGRect(x: 40, y: 4, width: 220, height: 40)
        ctx.fill(Path(roundedRect: pointSize, cornerRadius: 12), with: .color(Color(white: 0.32)))
        ctx.fill(Path(roundedRect: pointSize.insetBy(dx: 10, dy: 8).offsetBy(dx: 0, dy: -2), cornerRadius: 6), with: .color(Color(white: 0.42)))
        var slot = Path()
        slot.move(to: CGPoint(x: pointSize.minX + 14, y: pointSize.maxY - 3))
        slot.addLine(to: CGPoint(x: pointSize.maxX - 14, y: pointSize.maxY - 3))
        ctx.stroke(slot, with: .color(.black.opacity(0.55)), lineWidth: 2)
        let carriageX = sensor?.x ?? home.x
        let carriage = CGRect(x: carriageX - 9, y: pointSize.maxY - 12, width: 18, height: 12)
        ctx.fill(Path(roundedRect: carriage, cornerRadius: 3), with: .color(Color(white: 0.85)))
        if let sensor {
            var bundle = Path()
            bundle.move(to: CGPoint(x: carriage.midX - 3, y: carriage.maxY))
            bundle.addLine(to: CGPoint(x: sensor.x - 7, y: sensor.y))
            bundle.addLine(to: CGPoint(x: sensor.x + 7, y: sensor.y))
            bundle.addLine(to: CGPoint(x: carriage.midX + 3, y: carriage.maxY))
            bundle.closeSubpath()
            ctx.fill(bundle, with: .color(Color.accentColor.opacity(0.16)))
            let brightness = Path(ellipseIn: CGRect(x: sensor.x - 8, y: sensor.y - 8, width: 16, height: 16))
            ctx.fill(brightness, with: .radialGradient(Gradient(colors: [Color.accentColor.opacity(0.9), Color.accentColor.opacity(0)]),
                                                     center: sensor, startRadius: 0, endRadius: 8))
        }
    }

    /// Marks on the illustration's sheet (in the sheet's coordinates).
    private static var marks: [CGRect] {
        let f = sheet, r = indentation, q = square, l = cornerMark, e = strokeWidth
        return [CGRect(x: r, y: r, width: q, height: q),
                CGRect(x: f.width - r - l, y: r, width: l, height: e), CGRect(x: f.width - r - e, y: r, width: e, height: l),
                CGRect(x: r, y: f.height - r - e, width: l, height: e), CGRect(x: r, y: f.height - r - l, width: e, height: l)]
    }

    /// Center of the square and corners of the two corner marks (in the sheet's coordinates).
    private static var targets: [CGPoint] {
        let f = sheet, r = indentation
        return [CGPoint(x: r + square / 2, y: r + square / 2),
                CGPoint(x: f.width - r - 4, y: r + 4),
                CGPoint(x: r + 4, y: f.height - r - 4)]
    }

    private static func easeInOut(_ x: Double) -> Double {
        let v = min(max(x, 0), 1)
        return v * v * (3 - 2 * v)
    }
}
