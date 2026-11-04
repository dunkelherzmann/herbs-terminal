// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HerbsTerminal",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "HerbsTerminalUI", targets: ["HerbsTerminalUI"]),
        .executable(name: "HerbsTerminal", targets: ["HerbsTerminal"])
    ],
    dependencies: [.package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.20.0")],
    targets: [
        .target(name: "HerbsTerminalUI"),
        .executableTarget(name: "HerbsTerminal", dependencies: [
            "HerbsTerminalUI", .product(name: "SwiftTerm", package: "SwiftTerm")
        ]),
        .testTarget(name: "HerbsTerminalTests", dependencies: ["HerbsTerminal"])
    ]
)
