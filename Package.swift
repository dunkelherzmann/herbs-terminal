// swift-tools-version: 6.0
// The macOS app (macos/). SwiftPM needs every target's sources inside the package folder, so this manifest stays at
// the repository root: the app target takes macos/Sources/HerbsTerminal plus shared/, the SSH, SFTP, login-vault
// and shell-integration sources the Linux and Windows versions build too.
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
        .target(name: "HerbsTerminalUI", path: "macos/Sources/HerbsTerminalUI"),
        .executableTarget(
            name: "HerbsTerminal",
            dependencies: ["HerbsTerminalUI", .product(name: "SwiftTerm", package: "SwiftTerm")],
            path: ".",
            sources: ["macos/Sources/HerbsTerminal", "shared"]
        ),
        .testTarget(name: "HerbsTerminalTests", dependencies: ["HerbsTerminal"], path: "macos/Tests/HerbsTerminalTests")
    ]
)
