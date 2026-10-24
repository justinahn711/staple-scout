// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ThriftyMarketServer",
    platforms: [.macOS(.v14)],
    products: [.library(name: "SharedMarketCore", targets: ["SharedMarketCore"]), .executable(name: "ThriftyMarketServer", targets: ["MarketServer"]), .executable(name: "ThriftyMarketSessionAdmin", targets: ["SessionAdmin"]), .executable(name: "ThriftyMarketMaintenance", targets: ["Maintenance"])],
    dependencies: [
        .package(path: "../iOS/Packages/StapleScoutKit"),
        .package(url: "https://github.com/vapor/vapor.git", exact: "4.122.2"),
        .package(url: "https://github.com/swift-server/async-http-client.git", exact: "1.36.2")
    ],
    targets: [
        .systemLibrary(name: "CSQLite", pkgConfig: "sqlite3", providers: [.apt(["libsqlite3-dev"]), .brew(["sqlite3"])]),
        .target(name: "ServiceOwnership"),
        .target(name: "SharedMarketCore", dependencies: [.product(name: "StapleScoutKit", package: "StapleScoutKit"), "CSQLite", "ServiceOwnership"]),
        .target(name: "ClientSessions", dependencies: ["CSQLite", "ServiceOwnership"]),
        .target(name: "ProviderBudgets", dependencies: ["ClientSessions", "CSQLite", "ServiceOwnership", .product(name: "AsyncHTTPClient", package: "async-http-client")]),
        .target(name: "MarketHTTP", dependencies: ["SharedMarketCore", "ClientSessions", "ProviderBudgets", .product(name: "StapleScoutKit", package: "StapleScoutKit"), .product(name: "Vapor", package: "vapor")]),
        .executableTarget(name: "MarketServer", dependencies: ["ServiceOwnership", "MarketHTTP", "ClientSessions", "ProviderBudgets", .product(name: "Vapor", package: "vapor")]),
        .executableTarget(name: "SessionAdmin", dependencies: ["ClientSessions"]),
        .executableTarget(name: "Maintenance", dependencies: ["ServiceOwnership", "ClientSessions", "SharedMarketCore", "ProviderBudgets"]),
        .testTarget(name: "RetentionTests", dependencies: ["ClientSessions", "SharedMarketCore", "ProviderBudgets", "ServiceOwnership", "CSQLite", .product(name: "StapleScoutKit", package: "StapleScoutKit")]),
        .testTarget(name: "ClientSessionsTests", dependencies: ["ClientSessions", "CSQLite"]),
        .testTarget(name: "ProviderBudgetsTests", dependencies: ["ServiceOwnership", "ProviderBudgets", "ClientSessions", "SharedMarketCore", .product(name: "StapleScoutKit", package: "StapleScoutKit")]),
        .testTarget(name: "SharedMarketCoreTests", dependencies: ["CSQLite", "SharedMarketCore", .product(name: "StapleScoutKit", package: "StapleScoutKit")]),
        .testTarget(name: "MarketHTTPTests", dependencies: ["MarketHTTP", "ClientSessions", "ProviderBudgets", .product(name: "VaporTesting", package: "vapor")])
    ],
    swiftLanguageModes: [.v5]
)
