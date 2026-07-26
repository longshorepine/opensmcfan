// swift-tools-version:5.3
import PackageDescription

let package = Package(
    name: "MySMC",
    platforms: [
        .macOS(.v10_15),
    ],
    products: [
        .executable(name: "mysmc", targets: ["mysmc"]),
        .library(name: "SMCKit", targets: ["SMCKit"]),
        .library(name: "MySMCCore", targets: ["MySMCCore"]),
    ],
    targets: [
        // C header defining SMC structs — guarantees kernel ABI layout
        .target(
            name: "CSMCTypes",
            path: "Sources/CSMCTypes"
        ),

        // Low-level SMC read/write via IOKit
        .target(
            name: "SMCKit",
            dependencies: ["CSMCTypes"],
            linkerSettings: [
                .linkedFramework("IOKit"),
            ]
        ),

        // Domain logic: fans, curves, profiles, thermal engine
        .target(
            name: "MySMCCore",
            dependencies: ["SMCKit"]
        ),

        // CLI executable
        .target(
            name: "mysmc",
            dependencies: ["MySMCCore"]
        ),
    ]
)
