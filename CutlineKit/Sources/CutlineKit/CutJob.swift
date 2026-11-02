// Trabalho de corte: várias camadas, cada uma com sua força/velocidade/lâmina/passadas.
// Porte de `nucleo.cortar()`, do protótipo em Python que conferiu o driver (fora do repositório).
import CoreGraphics
import Foundation

/// Ajustes de um corte. Faixas da Portrait 3/4: velocidade 1–30 (1–10 nas antigas),
/// força 1–33, lâmina (AutoBlade) 1–10, passadas 1–5.
public struct CutSettings: Sendable, Hashable, Codable {
    public var speed: Int
    public var force: Int
    public var blade: Int
    public var passes: Int

    public init(speed: Int, force: Int, blade: Int, passes: Int) {
        self.speed = speed
        self.force = force
        self.blade = blade
        self.passes = passes
    }

    public static let forceRange = 1...33
    public static let bladeRange = 1...10
    public static let passesRange = 1...5
}

/// Caminhos cortados com os mesmos ajustes (no app: uma cor de linha).
public struct CutLayer: Sendable {
    public var name: String
    /// Em mm, coordenadas da página (origem no canto superior esquerdo).
    public var paths: [[CGPoint]]
    public var settings: CutSettings

    public init(name: String, paths: [[CGPoint]], settings: CutSettings) {
        self.name = name
        self.paths = paths
        self.settings = settings
    }
}

/// Onde o corte está: camada (1…n) e passada (1…n), para mostrar o andamento.
public struct CutProgress: Sendable {
    public let layer: Int
    public let layerCount: Int
    public let layerName: String
    public let pass: Int
    public let passCount: Int
}

public struct MachineInfo: Sendable {
    public let model: String
    public let firmware: String
    public let status: Cutter.Status
    /// Protocolo novo (Portrait 3/4, Cameo 4/5): lâmina ajustada pela máquina.
    public let autoblade: Bool
    public let maxSpeed: Int
}

extension Cutter {
    public static let a4 = CGSize(width: 210, height: 297)

    public func info() async throws -> MachineInfo {
        let autoblade = hardware.isCameo4Line
        let status = try await status()
        let firmware = try await firmwareVersion() ?? ""
        return MachineInfo(model: hardware.name, firmware: firmware.trimmingCharacters(in: .whitespacesAndNewlines),
                           status: status, autoblade: autoblade, maxSpeed: autoblade ? 30 : 10)
    }

    public nonisolated func validate(_ settings: CutSettings, maxSpeed: Int) throws {
        guard (1...maxSpeed).contains(settings.speed) else {
            throw CutterError.invalidSettings(localized("Velocidade deve ficar entre 1 e \(maxSpeed) neste modelo."))
        }
        guard CutSettings.forceRange.contains(settings.force) else {
            throw CutterError.invalidSettings(localized("Força deve ficar entre 1 e 33."))
        }
        guard CutSettings.bladeRange.contains(settings.blade) else {
            throw CutterError.invalidSettings(localized("Lâmina deve ficar entre 1 e 10."))
        }
        guard CutSettings.passesRange.contains(settings.passes) else {
            throw CutterError.invalidSettings(localized("Passadas devem ficar entre 1 e 5."))
        }
    }

    /// Corta as camadas na ordem dada (no adesivo: primeiro o meio-corte de dentro, por último
    /// o corte total de fora). Com `registration`, lê as marcas antes e só volta à origem no fim,
    /// para não perder o registro. `cuttingMat` falso = sem base de corte (a máquina puxa a folha direto, `TG0`);
    /// `mat` escolhe a base (nil = a padrão da máquina).
    @discardableResult
    public func cut(_ layers: [CutLayer], info: MachineInfo, media: CGSize = Cutter.a4,
                    registration: Registration? = nil, cuttingMat: Bool = true, mat: CuttingMat? = nil,
                    onProgress: (@Sendable (CutProgress) -> Void)? = nil) async throws -> Status {
        guard !layers.isEmpty else { throw CutterError.invalidSettings(localized("Nada para cortar.")) }
        for layer in layers { try validate(layer.settings, maxSpeed: info.maxSpeed) }

        if registration == nil {
            let points = layers.flatMap(\.paths).flatMap { $0 }
            let outside = points.contains { $0.x < 0 || $0.y < 0 || $0.x > media.width || $0.y > media.height }
            if outside {
                throw CutterError.outOfBounds(localized("As formas saem da base (\(Int(media.width)) × \(Int(media.height)) mm)."))
            }
        }
        if info.status == .unloaded, !isSimulated { throw CutterError.mediaNotLoaded }

        let total = layers.reduce(0) { $0 + $1.settings.passes }
        var count = 0
        for (index, layer) in layers.enumerated() {
            let s = layer.settings
            log("== \(layer.name): velocidade=\(s.speed) força=\(s.force) lâmina=\(s.blade) passadas=\(s.passes)")
            if !info.autoblade { log("! Lâmina manual: confira se está no nível \(s.blade).") }
            // Termina a camada anterior antes de trocar a configuração.
            if index > 0, !isSimulated { try await waitForReady(timeout: 300) }

            var setup = SetupOptions()
            setup.speed = s.speed
            setup.pressure = s.force
            setup.depth = s.blade
            setup.autoblade = info.autoblade
            setup.cuttingMat = cuttingMat ? (mat ?? hardware.defaultCuttingMat) : CuttingMat.none
            setup.mediaWidth = media.width
            setup.mediaHeight = media.height
            setup.skipInit = index > 0
            try await self.setup(setup)

            for pass in 0..<s.passes {
                count += 1
                onProgress?(CutProgress(layer: index + 1, layerCount: layers.count, layerName: layer.name,
                                        pass: pass + 1, passCount: s.passes))
                var plot = PlotOptions()
                plot.mediaWidth = media.width
                plot.mediaHeight = media.height
                plot.endPosition = .start
                plot.registration = registration
                plot.skipInit = count > 1
                plot.skipReset = registration != nil ? count < total : pass < s.passes - 1
                if registration != nil, count == 1 { log("Lendo as marcas de registro (até ~40 s)…") }
                try await self.plot(layer.paths, plot)
            }
        }
        return isSimulated ? .ready : try await waitForReady(timeout: 300)
    }
}
