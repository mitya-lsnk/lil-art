// swift-tools-version:6.0
import PackageDescription

// The part of lil art that needs neither the engine nor a window: file formats, settings,
// text rules. `swift test` here takes seconds. build.sh copies these files into the app, so
// the app is built exactly as before.
//
// LilKitShared is the lil suite's shared Swift file (LilKit.swift, with the generated LilApp.swift
// beside it) seen through links to the copies in the app, so its settings store is tested as it
// really is. In the app the same files simply lie in one module with the rest.
let package = Package(
  name: "LilArtCore",
  platforms: [.macOS("26.0")],
  targets: [
    .target(name: "LilKitShared", swiftSettings: [.swiftLanguageMode(.v5)]),
    .target(name: "LilArtCore", dependencies: ["LilKitShared"], swiftSettings: [.swiftLanguageMode(.v5)]),
    .testTarget(name: "LilArtCoreTests", dependencies: ["LilArtCore", "LilKitShared"],
                swiftSettings: [.swiftLanguageMode(.v5)]),
  ]
)
