// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Macarok",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Macarok", targets: ["MacarokApp"]),
        .library(name: "MacarokCore", targets: ["MacarokCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.12.0"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts.git", exact: "3.1.0"),
        .package(url: "https://github.com/sbooth/CXXTagLib.git", revision: "9e499ea0a69d107791ac0a2fe9d6a59cf401c6f9"),
    ],
    targets: [
        .target(name: "MacarokCore", dependencies: [.product(name: "GRDB", package: "GRDB.swift")]),
        .target(name: "MacarokTagBridge", dependencies: [.product(name: "taglib", package: "CXXTagLib")], publicHeadersPath: "include", linkerSettings: [.linkedFramework("Foundation")]),
        .target(name: "MacarokMetadata", dependencies: ["MacarokTagBridge", "MacarokCore"]),
        .binaryTarget(name: "VLCKit", url: "https://download.videolan.org/cocoapods/unstable/VLCKit-4.0-20261109-1916.zip", checksum: "1fec7232f88e706f44d9a015133e08d742166eb2666cb44915c9f570bf339463"),
        .target(name: "MacarokAudio", dependencies: ["VLCKit"]),
        .executableTarget(name: "MacarokApp", dependencies: ["MacarokCore", "MacarokAudio", "MacarokMetadata", .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts")], linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "MacarokCoreTests", dependencies: ["MacarokCore"]),
        .testTarget(name: "MacarokMetadataTests", dependencies: ["MacarokMetadata", "MacarokCore"], resources: [.copy("Fixtures")]),
        .testTarget(name: "MacarokAudioTests", dependencies: ["MacarokAudio", "MacarokCore"], resources: [.copy("Fixtures")]),
        .testTarget(name: "MacarokAppTests", dependencies: ["MacarokApp", "MacarokCore", "MacarokMetadata", .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts")]),
    ],
    swiftLanguageModes: [.v5],
    cxxLanguageStandard: .cxx17
)
