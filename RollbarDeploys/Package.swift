// swift-tools-version:5.7.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "RollbarDeploys",
    platforms: [
        // Oldest targeted platform versions that are supported by this product.
        .macOS(.v10_15),
        .iOS(.v13),
        .tvOS(.v13),
        .watchOS(.v7),
    ],
    products: [
        // Products define the executables and libraries produced by a package, and make them visible to other packages.
        .library(
            name: "RollbarDeploys",
            targets: ["RollbarDeploys"]),
    ],
    dependencies: [
        // Dependencies declare other packages that this package depends on.
        // .package(url: /* package url */, from: "1.0.0"),
        .package(path: "../RollbarCommon"),
        .package(path: "../UnitTesting"),
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target can define a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages which this package depends on.
        .target(
            name: "RollbarDeploys",
            dependencies: ["RollbarCommon",],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("Sources/RollbarDeploys/**"),
//                .headerSearchPath("Sources/RollbarDeploys"),
//                .headerSearchPath("Sources/RollbarDeploys/include"),
//                .headerSearchPath("Sources/RollbarDeploys/DTOs"),
                
//                .define("DEFINES_MODULE"),
            ]
        ),
        .testTarget(
            name: "RollbarDeploysTests",
            dependencies: [
                "UnitTesting",
                "RollbarDeploys",
            ]
        ),
        .testTarget(
            name: "RollbarDeploysTests-ObjC",
            dependencies: [
                "UnitTesting",
                "RollbarDeploys",
            ],
            cSettings: [
                .headerSearchPath("Tests/RollbarDeploysTests-ObjC/**"),
//                .headerSearchPath("Sources/RollbarDeploys"),
//                .headerSearchPath("Sources/RollbarDeploys/include"),
//                .headerSearchPath("Sources/RollbarDeploys/DTOs"),
                
//                .define("DEFINES_MODULE"),
            ]
        ),
    ],
    swiftLanguageVersions: [
        SwiftVersion.v4,
        SwiftVersion.v4_2,
        SwiftVersion.v5,
    ]
)
