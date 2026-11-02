// swift-tools-version: 6.0
// CutlineKit — driver for Silhouette cutters (the GPGL protocol over Bluetooth LE or USB).
// Port of the `silhouette/` module of inkscape-silhouette @ f166edc (GPL), https://github.com/fablabnbg/inkscape-silhouette.
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
