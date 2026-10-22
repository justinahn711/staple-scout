// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ThriftyMarketServer",
    platforms: [.macOS(.v14)],
    products: [.library(name: "SharedMarketCore", targets: ["SharedMarketCore"]), .executable(name: "ThriftyMarketServer", targets: ["MarketServer"]), .executable(name: "ThriftyMarketSessionAdmin", targets: ["SessionAdmin"])],
    dependencies: [
        .package(path: "../iOS/Packages/StapleScoutKit"),
        .package(url: "https://github.com/vapor/vapor.git", exact: "4.122.2")
    ],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3", providers: [.apt(["libsqlite3-dev"]), .brew(["sqlite3"])]),
        .target(name: "SharedMarketCore", dependencies: [.product(name: "StapleScoutKit", package: "StapleScoutKit"), "CSQLite"]),
        .target(name: "ClientSessions", dependencies: ["CSQLite"]),
        .target(name: "MarketHTTP", dependencies: ["SharedMarketCore", "ClientSessions", .product(name: "StapleScoutKit", package: "StapleScoutKit"), .product(name: "Vapor", package: "vapor")]),
        .executableTarget(name: "MarketServer", dependencies: ["MarketHTTP", "ClientSessions", .product(name: "Vapor", package: "vapor")]),
        .executableTarget(name: "SessionAdmin", dependencies: ["ClientSessions"]),
        .testTarget(name: "ClientSessionsTests", dependencies: ["ClientSessions", "CSQLite"]),
        .testTarget(name: "SharedMarketCoreTests", dependencies: ["SharedMarketCore", .product(name: "StapleScoutKit", package: "StapleScoutKit")]),
        .testTarget(name: "MarketHTTPTests", dependencies: ["MarketHTTP", "ClientSessions", .product(name: "VaporTesting", package: "vapor")])
    ],
    swiftLanguageModes: [.v5]
)
