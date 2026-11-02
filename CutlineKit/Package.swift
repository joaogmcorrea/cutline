// swift-tools-version: 6.0
// CutlineKit — driver das cortadoras Silhouette (protocolo GPGL sobre Bluetooth LE ou USB).
// Porte do módulo `silhouette/` do inkscape-silhouette @ f166edc (GPL), https://github.com/fablabnbg/inkscape-silhouette.
// Os testes, o `cutline` (linha de comando) e o `conferir` ficam fora do repositório, em _dev/testes/.
import PackageDescription

let package = Package(
    name: "CutlineKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CutlineKit", targets: ["CutlineKit"]),
    ],
    targets: [
        .target(name: "CutlineKit"),
    ]
)
