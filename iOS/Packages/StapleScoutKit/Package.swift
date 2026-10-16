// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "StapleScoutKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "StapleScoutKit", targets: ["StapleScoutKit"])],
    targets: [.target(name: "StapleScoutKit"), .testTarget(name: "StapleScoutKitTests", dependencies: ["StapleScoutKit"], resources: [.process("Fixtures")])]
)
