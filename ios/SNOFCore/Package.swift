// swift-tools-version:6.0
// The pure logic of the SNOF iOS app: the RTDB shape, the rules for what is
// on / offline / operable, and the bridge gate. Foundation only, so
// `swift test` runs on a Mac with no simulator and no Firebase — the same
// role tests/test_logic.py plays for the add-on.
import PackageDescription

let package = Package(
    name: "SNOFCore",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [.library(name: "SNOFCore", targets: ["SNOFCore"])],
    targets: [
        .target(name: "SNOFCore", swiftSettings: [.swiftLanguageMode(.v5)]),
        .testTarget(name: "SNOFCoreTests", dependencies: ["SNOFCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
    ]
)
