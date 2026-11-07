// Whether the artboard being sent fits what the machine and the mat cut (the Send window's warning), as it goes on the
// mat (`Document.sheetFrame`: a landscape artboard turned): its width across the machine, its height along the feed.
import CutlineKit
import Foundation

enum SendSize {
    /// The warning, or nil when it fits. Only past the machine's width or the mat: without a mat the machine feeds
    /// as long a sheet as it takes.
    static func warning(size: CGSize, hardware: Hardware, mat: CuttingMat, machineName: String) -> String? {
        let unit = LengthUnit.current
        if let width = hardware.widthMM, size.width > width + 0.5 {
            return String(localized: "On the mat, this artboard is \(unit.text(size.width)) wide, and the \(machineName) cuts up to \(unit.text(width)): what is past that isn’t cut.")
        }
        if let matSize = mat.sizeMM, size.width > matSize.width + 0.5 || size.height > matSize.height + 0.5 {
            return String(localized: "On the mat, this artboard (\(unit.text(size))) is larger than the \(mat.name) (\(unit.text(matSize))): what is past the mat isn’t cut.")
        }
        return nil
    }
}
