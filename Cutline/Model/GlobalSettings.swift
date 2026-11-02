// Cut settings kept in the app (they apply to any file): the last ones used for each line
// color and the user's materials ("My materials"). Each file still keeps its own — on
// opening, the file's apply; colors the file doesn't have start with the ones remembered here.
import Foundation
import Observation
import CutlineKit

@Observable
final class GlobalSettings {
    static let shared = GlobalSettings()

    private(set) var byColor: [CMYK: CutConfig] = [:]
    private(set) var materials: [Material] = []

    private static let colorsKey = "ajustesPorCor"
    private static let materialsKey = "meusMateriais"

    private struct SavedColor: Codable {

        /// The keys stored on disk keep the names of the 1.0 format (Portuguese), so older files still open.

        enum CodingKeys: String, CodingKey {

            case color = "cor", config

        }

        var color: CMYK
        var config: CutConfig
    }

    private init() {
        let defaults = UserDefaults.standard
        if let payload = defaults.data(forKey: Self.colorsKey),
           let list = try? JSONDecoder().decode([SavedColor].self, from: payload) {
            byColor = Dictionary(list.map { ($0.color, $0.config) }, uniquingKeysWith: { _, last in last })
        }
        if let payload = defaults.data(forKey: Self.materialsKey), let list = try? JSONDecoder().decode([Material].self, from: payload) {
            materials = list
        }
    }

    /// Remembers this color's settings for the next files.
    func remember(_ config: CutConfig, to color: CMYK) {
        guard byColor[color] != config else { return }
        byColor[color] = config
        let list = byColor.map { SavedColor(color: $0.key, config: $0.value) }
        if let payload = try? JSONEncoder().encode(list) { UserDefaults.standard.set(payload, forKey: Self.colorsKey) }
    }

    // MARK: My materials

    /// The app's and the user's, in that order.
    var allMaterials: [Material] { Material.all + materials }

    func material(_ name: String) -> Material? { allMaterials.first { $0.name == name } }

    func isUserMaterial(_ name: String) -> Bool { materials.contains { $0.name == name } }

    /// Creates or updates a user material (the app's don't change). Returns false if the name belongs to an app one.
    @discardableResult
    func saveMaterial(_ name: String, settings: CutSettings) -> Bool {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, !Material.all.contains(where: { $0.name == name }) else { return false }
        let updated = Material(name: name, settings: settings)
        if let i = materials.firstIndex(where: { $0.name == name }) { materials[i] = updated } else { materials.append(updated) }
        saveMaterials()
        return true
    }

    func deleteMaterial(_ name: String) {
        materials.removeAll { $0.name == name }
        saveMaterials()
    }

    private func saveMaterials() {
        if let payload = try? JSONEncoder().encode(materials) { UserDefaults.standard.set(payload, forKey: Self.materialsKey) }
    }
}
