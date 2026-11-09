// swift-tools-version: 6.0
import PackageDescription

// Herb's Terminal for Linux: GTK 4, libadwaita and VTE, packaged as a Flatpak (see org.herbsterminal.app.yml).
// The SSH, SFTP and login-vault code is the macOS app's own (shared/ at the repository root, copied into Sources/HerbsTerminal/Shared by copy-shared.sh); the small
// Darwin, CryptoKit and CommonCrypto modules here give that code the same names on Linux.
let package = Package(
    name: "HerbsTerminalLinux",
    targets: [
        .systemLibrary(name: "CGtk", path: "Sources/CGtk", pkgConfig: "gtk4 libadwaita-1 vte-2.91-gtk4 gtksourceview-5"),
        .systemLibrary(name: "SQLite3", path: "Sources/SQLite3", pkgConfig: "sqlite3"),
        .systemLibrary(name: "COpenSSL", path: "Sources/COpenSSL", pkgConfig: "libcrypto"),
        .target(name: "CHerb", dependencies: ["CGtk"], path: "Sources/CHerb"),
        .target(name: "Darwin", path: "Sources/Darwin"),
        .target(name: "CryptoKit", dependencies: ["COpenSSL"], path: "Sources/CryptoKit"),
        .target(name: "CommonCrypto", dependencies: ["COpenSSL"], path: "Sources/CommonCrypto"),
        .executableTarget(
            name: "HerbsTerminal",
            dependencies: ["CGtk", "CHerb", "SQLite3", "Darwin", "CryptoKit", "CommonCrypto"],
            path: "Sources/HerbsTerminal",
            swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
