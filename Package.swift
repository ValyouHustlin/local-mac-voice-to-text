// swift-tools-version:6.0
import Foundation
import PackageDescription

let commandLineToolsTestingInterop =
    "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
let environment = ProcessInfo.processInfo.environment
let usesCommandLineToolsOnly =
    environment["TOOLCHAINS"] == nil
    && (
        environment["DEVELOPER_DIR"]?.contains("CommandLineTools")
        ?? !FileManager.default.fileExists(atPath: "/Applications/Xcode.app")
    )
let needsTestingInteropPath =
    usesCommandLineToolsOnly
    && FileManager.default.fileExists(
        atPath: "\(commandLineToolsTestingInterop)/lib_TestingInterop.dylib"
    )
let testLinkerSettings: [LinkerSetting] = needsTestingInteropPath ? [
    .unsafeFlags([
        "-L", commandLineToolsTestingInterop,
        "-Xlinker", "-rpath",
        "-Xlinker", commandLineToolsTestingInterop,
    ]),
] : []

let package = Package(
    name: "wordhand",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: [
        .library(name: "WordhandCore", targets: ["WordhandCore"]),
        .library(name: "WordhandMobileCore", targets: ["WordhandMobileCore"]),
        .executable(name: "wordhand", targets: ["wordhand"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/argmaxinc/WhisperKit.git", from: "0.9.0"),
        .package(
            url: "https://github.com/swiftlang/swift-testing.git",
            revision: "swift-6.3.1-RELEASE"
        ),
    ],
    targets: [
        .target(
            name: "WordhandCore",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .target(
            name: "WordhandMobileCore",
            dependencies: ["WordhandCore"]
        ),
        .executableTarget(
            name: "wordhand",
            dependencies: [
                "WordhandCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "WhisperKit", package: "WhisperKit"),
            ]
        ),
        .testTarget(
            name: "WordhandCoreTests",
            dependencies: [
                "WordhandCore",
                .product(name: "Testing", package: "swift-testing"),
            ],
            linkerSettings: testLinkerSettings
        ),
        .testTarget(
            name: "WordhandMobileCoreTests",
            dependencies: [
                "WordhandCore",
                "WordhandMobileCore",
                .product(name: "Testing", package: "swift-testing"),
            ],
            linkerSettings: testLinkerSettings
        ),
    ],
    swiftLanguageModes: [.v5]
)
