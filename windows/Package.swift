// swift-tools-version: 6.0
import PackageDescription

// Herb's Terminal for Windows: a Win32 app with SwiftTerm's terminal engine and ConPTY.
// The login-vault code is the macOS app's own (dev\build.ps1 copies the files listed in shared.txt into
// Sources\HerbsTerminal\Shared); the small Darwin, CryptoKit, CommonCrypto and SQLite3 modules here give that code
// the same names on Windows, on the Universal CRT, Windows CNG and the system's winsqlite3.
let package = Package(
    name: "HerbsTerminalWindows",
    dependencies: [.package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.20.0")],
    targets: [
        .systemLibrary(name: "SQLite3", path: "Sources/SQLite3"),
        .target(name: "Darwin", path: "Sources/Darwin", linkerSettings: [.linkedLibrary("ws2_32")]),
        .target(name: "CryptoKit", path: "Sources/CryptoKit", linkerSettings: [.linkedLibrary("bcrypt")]),
        .target(name: "CommonCrypto", dependencies: ["CryptoKit"], path: "Sources/CommonCrypto"),
        .executableTarget(
            name: "HerbsTerminal",
            dependencies: ["SQLite3", "Darwin", "CryptoKit", "CommonCrypto", .product(name: "SwiftTerm", package: "SwiftTerm")],
            path: "Sources/HerbsTerminal",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedLibrary("user32"), .linkedLibrary("gdi32"), .linkedLibrary("comctl32"),
                .linkedLibrary("shell32"), .linkedLibrary("ole32"), .linkedLibrary("dwmapi"),
                .linkedLibrary("comdlg32"), .linkedLibrary("uxtheme"), .linkedLibrary("advapi32"),
                .unsafeFlags(["-Xlinker", "/SUBSYSTEM:WINDOWS", "-Xlinker", "/ENTRY:mainCRTStartup",
                              // Common Controls 6: current-style buttons, drop-downs and fields.
                              "-Xlinker", "/MANIFEST:EMBED",
                              "-Xlinker", "/MANIFESTDEPENDENCY:type='win32' name='Microsoft.Windows.Common-Controls' version='6.0.0.0' processorArchitecture='*' publicKeyToken='6595b64144ccf1df' language='*'"]),
            ]),
    ]
)
