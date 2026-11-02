// Cutter models and cutting mats.
// Port of the DEVICE, CAMEO_MATS and BLUETOOTH_NAME_TO_PRODUCT_ID tables from Graphtec.py (GPLv2).
import Foundation

public struct Hardware: Sendable, Hashable {
    public let name: String
    public let vendorID: UInt16?
    public let productID: UInt16?
    public let widthMM: Double?
    public let lengthMM: Double?
    public let marginLeftMM: Double?
    public let marginTopMM: Double?
    public let regmark: Bool
    public let quadRegmarks: Bool
    public let maxPressure: Int?

    init(_ name: String, vendor: UInt16 = Hardware.vendorGraphtec, product: UInt16?, width: Double? = nil,
         length: Double? = nil, marginLeft: Double? = nil, marginTop: Double? = nil, regmark: Bool = false,
         quadRegmarks: Bool = false, maxPressure: Int? = nil) {
        self.name = name
        self.vendorID = product == nil ? nil : vendor
        self.productID = product
        self.widthMM = width
        self.lengthMM = length
        self.marginLeftMM = marginLeft
        self.marginTopMM = marginTop
        self.regmark = regmark
        self.quadRegmarks = quadRegmarks
        self.maxPressure = maxPressure
    }

    /// Unrecognized model (no product id): uses the old protocol's commands.
    public static func unknown(_ name: String) -> Hardware { Hardware(name, product: nil) }

    // MARK: IDs USB

    public static let vendorGraphtec: UInt16 = 0x0B4D
    public static let vendorCameo5Alpha: UInt16 = 0x3844

    public static let idCC200_20: UInt16 = 0x110A
    public static let idCC300_20: UInt16 = 0x111A
    public static let idSD1: UInt16 = 0x111C
    public static let idSD2: UInt16 = 0x111D
    public static let idCameo: UInt16 = 0x1121
    public static let idCameo2: UInt16 = 0x112B
    public static let idCameo3: UInt16 = 0x112F
    public static let idCameo4: UInt16 = 0x1137
    public static let idCameo4Plus: UInt16 = 0x1138
    public static let idCameo4Pro: UInt16 = 0x1139
    public static let idCameo5: UInt16 = 0x1140
    public static let idCameo5Plus: UInt16 = 0x1141
    public static let idCameoProMkII: UInt16 = 0x1146
    public static let idCameo5Alpha: UInt16 = 0x0001
    public static let idCameo5AlphaPlus: UInt16 = 0x0002
    public static let idPortrait: UInt16 = 0x1123
    public static let idPortrait2: UInt16 = 0x1132
    public static let idPortrait3: UInt16 = 0x113A
    public static let idPortrait4: UInt16 = 0x113F

    /// New protocol (speed 1–30, AutoBlade): Cameo 4/5 and Portrait 3/4.
    static let cameo4Line: Set<UInt16> = [
        idCameo4, idCameo4Plus, idCameo4Pro, idCameo5, idCameo5Plus, idCameoProMkII,
        idCameo5Alpha, idCameo5AlphaPlus, idPortrait3, idPortrait4,
    ]
    static let cameo3On: Set<UInt16> = cameo4Line.union([idCameo3])
    static let twoTools: Set<UInt16> = cameo3On.subtracting([idPortrait3, idPortrait4])

    var isCameo4Line: Bool { productID.map(Self.cameo4Line.contains) ?? false }
    var isCameo3On: Bool { productID.map(Self.cameo3On.contains) ?? false }
    var hasTwoTools: Bool { productID.map(Self.twoTools.contains) ?? false }
    var isCameo3: Bool { productID == Self.idCameo3 }

    // MARK: Model table

    public static let all: [Hardware] = [
        Hardware("Silhouette_Portrait", product: idPortrait, width: 206, length: 3000, regmark: true),
        Hardware("Silhouette_Portrait2", product: idPortrait2, width: 203, length: 3000, regmark: true),
        Hardware("Silhouette_Portrait3", product: idPortrait3, width: 203, length: 18290, regmark: true),
        Hardware("Silhouette_Portrait4", product: idPortrait4, width: 216, length: 18290, regmark: true),
        Hardware("Silhouette_Cameo_Pro_MK-II", product: idCameoProMkII, width: 609, length: 18290, regmark: true,
                 quadRegmarks: true),
        Hardware("Silhouette_Cameo", product: idCameo, width: 304, length: 3000, marginLeft: 9, marginTop: 1,
                 regmark: true),
        Hardware("Silhouette_Cameo2", product: idCameo2, width: 304, length: 3000, marginLeft: 0, marginTop: 0,
                 regmark: true),
        Hardware("Silhouette_Cameo3", product: idCameo3, width: 304.8, length: 3000, marginLeft: 0, marginTop: 0,
                 regmark: true),
        Hardware("Silhouette_Cameo4", product: idCameo4, width: 304.8, length: 3000, marginLeft: 0, marginTop: 0,
                 regmark: true),
        Hardware("Silhouette_Cameo4_Plus", product: idCameo4Plus, width: 372, length: 3000, marginLeft: 0,
                 marginTop: 0, regmark: true),
        Hardware("Silhouette_Cameo4_Pro", product: idCameo4Pro, width: 600, length: 3000, marginLeft: 0,
                 marginTop: 0, regmark: true),
        Hardware("Silhouette_Cameo5", product: idCameo5, width: 330.2, length: 3000, marginLeft: 0, marginTop: 0,
                 regmark: true),
        Hardware("Silhouette_Cameo5_Plus", product: idCameo5Plus, width: 372, length: 3000, marginLeft: 0,
                 marginTop: 0, regmark: true),
        Hardware("Silhouette_Cameo5_Alpha", vendor: vendorCameo5Alpha, product: idCameo5Alpha, width: 330.2,
                 length: 3000, marginLeft: 0, marginTop: 0, regmark: true, quadRegmarks: true, maxPressure: 40),
        Hardware("Silhouette_Cameo5_Alpha_Plus", vendor: vendorCameo5Alpha, product: idCameo5AlphaPlus, width: 372,
                 length: 3000, marginLeft: 0, marginTop: 0, regmark: true, quadRegmarks: true, maxPressure: 40),
        Hardware("Craft_Robo_CC200-20", product: idCC200_20, width: 200, length: 1000, regmark: true),
        Hardware("Craft_Robo_CC300-20", product: idCC300_20),
        Hardware("Silhouette_SD_1", product: idSD1),
        Hardware("Silhouette_SD_2", product: idSD2),
    ]

    public static func named(_ name: String) -> Hardware? { all.first { $0.name == name } }
    public static func withProductID(_ id: UInt16) -> Hardware? { all.first { $0.productID == id } }
    public static func withUSB(vendor: UInt16, product: UInt16) -> Hardware? {
        all.first { $0.vendorID == vendor && $0.productID == product }
    }

    /// "Silhouette_Cameo4_Plus" → "Cameo 4 Plus" (no hyphen: the machine name uses the hyphen before the serial number).
    public var modelName: String {
        name.replacingOccurrences(of: "Silhouette_", with: "")
            .replacingOccurrences(of: #"[_-]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"([A-Za-z])(\d)"#, with: "$1 $2", options: .regularExpression)
    }

    public static let portrait4 = withProductID(idPortrait4)!
    public static let portrait3 = withProductID(idPortrait3)!

    // MARK: Bluetooth

    /// Bluetooth machines identify themselves by the advertised name and the FG response
    /// (e.g. "Portrait 4-0000001", "CAMEO 5 ALPHA V1.02"). Most specific first.
    static let bluetoothNames: [(String, UInt16)] = [
        ("CAMEO 5 ALPHA PLUS", idCameo5AlphaPlus),
        ("CAMEO 5 ALPHA", idCameo5Alpha),
        ("CAMEO 5 PLUS", idCameo5Plus),
        ("CAMEO 5", idCameo5),
        ("CAMEO PRO MARK2", idCameoProMkII),
        ("CAMEO 4 PLUS", idCameo4Plus),
        ("CAMEO 4 PRO", idCameo4Pro),
        ("CAMEO 4", idCameo4),
        ("CAMEO3", idCameo3),
        ("PORTRAIT4", idPortrait4),
        ("PORTRAIT3", idPortrait3),
        ("PORTRAIT2", idPortrait2),
    ]

    /// Name advertised over Bluetooth: model + "-" + the machine's serial number ("Portrait 4-0000001").
    /// Like Studio: only what comes before the 1st hyphen, compared whole (without spaces, case-insensitive).
    public static func match(bluetoothName: String?) -> Hardware? {
        guard let name = bluetoothName else { return nil }
        let key = modelKey(String(name.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)[0]))
        guard let entry = bluetoothNames.first(where: { modelKey($0.0) == key }) else { return nil }
        return withProductID(entry.1)
    }

    /// The model of a cutter found: by the name advertised over Bluetooth or, over USB, by the model name.
    public static func match(_ cutter: DiscoveredCutter?) -> Hardware? {
        guard let cutter else { return nil }
        return cutter.link == .usb ? all.first { $0.modelName == cutter.model } : match(bluetoothName: cutter.name)
    }

    /// FG response: model + version ("Portrait 4 V1.05", "CAMEO 5 ALPHA PLUS V1.00").
    public static func match(firmware: String?) -> Hardware? {
        guard let firmware else { return nil }
        let key = modelKey(firmware)
        guard !key.isEmpty, let entry = bluetoothNames.first(where: { key.hasPrefix(modelKey($0.0)) }) else { return nil }
        return withProductID(entry.1)
    }

    private static func modelKey(_ text: String) -> String {
        text.uppercased().filter { !$0.isWhitespace }
    }
}

/// Cutting mats (TG<code>) with the size in inches (length × width). Silhouette Studio 5's:
/// which each machine accepts, each one's default and the code each mat sends on each machine (mats
/// "from another machine" become one it knows, as Studio does).
public enum CuttingMat: String, Sendable, CaseIterable, Codable {
    case none = "no_mat"
    case cameo12x12 = "cameo_12x12"
    case cameo12x24 = "cameo_12x24"
    case portrait8x12 = "portrait_8x12"
    case cameoPlus15x15 = "cameo_plus_15x15"
    case cameoPro24x24 = "cameo_pro_24x24"
    case portrait8_5x12 = "portrait_8_5x12"
    case mini6x8 = "mini_6x8"
    case electrostatic12x12 = "electrostatic_12x12"
    case electrostatic8_5x12 = "electrostatic_8_5x12"
    case pixscanCameo = "pixscan_cameo"
    case pixscanPortrait = "pixscan_portrait"

    /// TG number (the 6 × 8 has none: it becomes the 8 × 12 or the 8.5 × 12, depending on the machine).
    var code: String {
        switch self {
        case .none: "0"
        case .cameo12x12: "1"
        case .cameo12x24: "2"
        case .portrait8x12, .mini6x8: "3"
        case .pixscanCameo: "4"
        case .pixscanPortrait: "5"
        case .cameoPlus15x15: "8"
        case .cameoPro24x24: "9"
        case .portrait8_5x12: "11"
        case .electrostatic12x12: "12"
        case .electrostatic8_5x12: "13"
        }
    }

    var sizeInches: (length: Double, width: Double)? {
        switch self {
        case .none, .pixscanCameo, .pixscanPortrait: nil
        case .cameo12x12, .electrostatic12x12: (12, 12)
        case .cameo12x24: (24, 12)
        case .portrait8x12: (12, 8)
        case .cameoPlus15x15: (15, 15)
        case .cameoPro24x24: (24, 24)
        case .portrait8_5x12, .electrostatic8_5x12: (12, 8.5)
        case .mini6x8: (8, 6)
        }
    }

    /// The mat the machine receives in the TG (like Studio's `make_carrier_id_compatible_with_cutter`): the Portrait
    /// 2/3 only knows the 8 × 12; the Portrait 4, the 8.5 × 12 (besides the electrostatic and PixScan ones); on the Cameos, the
    /// paper ones (6 × 8, 8 × 12) become the 8 × 12, and the large ones only apply to the Plus/Pro models (otherwise, 12 × 12).
    public func resolved(for hardware: Hardware) -> CuttingMat {
        guard self != .none else { return .none }
        switch hardware.productID {
        case Hardware.idPortrait, Hardware.idPortrait2, Hardware.idPortrait3:
            return .portrait8x12
        case Hardware.idPortrait4:
            return [.pixscanPortrait, .electrostatic8_5x12].contains(self) ? self : .portrait8_5x12
        default:
            let models = hardware.supportedCuttingMats
            if self == .mini6x8 { return .portrait8x12 }
            if [.cameoPlus15x15, .cameoPro24x24].contains(self) { return models.contains(self) ? self : .cameo12x12 }
            return [.cameo12x12, .cameo12x24, .portrait8x12, .pixscanCameo, .pixscanPortrait, .portrait8_5x12,
                    .electrostatic12x12].contains(self) ? self : .cameo12x12
        }
    }
}

extension Hardware {
    /// The mats Studio offers for the machine, in its order (the first is "no mat").
    public var supportedCuttingMats: [CuttingMat] {
        let cameo: [CuttingMat] = [.none, .cameo12x12, .cameo12x24, .portrait8x12, .mini6x8, .pixscanCameo]
        let cameo5: [CuttingMat] = [.electrostatic12x12, .cameo12x12, .cameo12x24, .portrait8_5x12, .mini6x8, .pixscanCameo]
        switch productID {
        case Self.idPortrait, Self.idPortrait2, Self.idPortrait3: return [.none, .portrait8x12, .mini6x8, .pixscanPortrait]
        case Self.idPortrait4: return [.none, .electrostatic8_5x12, .portrait8_5x12, .mini6x8, .pixscanPortrait]
        case Self.idCameo, Self.idCameo2, Self.idCameo3, Self.idCameo4: return cameo
        case Self.idCameo4Plus: return [.none, .cameoPlus15x15] + cameo.dropFirst()
        case Self.idCameo4Pro: return [.none, .cameoPro24x24, .cameoPlus15x15] + cameo.dropFirst()
        case Self.idCameo5, Self.idCameo5Alpha: return [.none] + cameo5
        case Self.idCameo5Plus, Self.idCameo5AlphaPlus: return [.none, .cameoPlus15x15] + cameo5
        case Self.idCameoProMkII:
            return [.none, .cameoPro24x24, .cameoPlus15x15, .cameo12x12, .cameo12x24, .portrait8x12, .portrait8_5x12, .mini6x8, .pixscanCameo]
        default: return [.none, .portrait8x12, .mini6x8]
        }
    }

    /// Each machine's mat when the user didn't choose another ("A4" doesn't exist in the protocol; the media goes
    /// as 210 × 297 mm).
    public var defaultCuttingMat: CuttingMat? {
        switch productID {
        case Self.idPortrait, Self.idPortrait2, Self.idPortrait3: .portrait8x12
        case Self.idPortrait4: .portrait8_5x12
        case Self.idCameo4Plus, Self.idCameo5Plus, Self.idCameo5AlphaPlus: .cameoPlus15x15
        case Self.idCameo4Pro, Self.idCameoProMkII: .cameoPro24x24
        case Self.idCameo, Self.idCameo2, Self.idCameo3, Self.idCameo4, Self.idCameo5, Self.idCameo5Alpha: .cameo12x12
        default: nil
        }
    }
}
