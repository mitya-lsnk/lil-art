// swift-tools-version:6.0
import PackageDescription

// The part of lil art that needs neither the engine nor a window: file formats, settings,
// text rules. `swift test` here takes seconds. build.sh copies these files into the app, so
// the app is built exactly as before.
let package = Package(
  name: "LilArtCore",
  platforms: [.macOS(.v13)],
  targets: [
    .target(name: "LilArtCore", swiftSettings: [.swiftLanguageMode(.v5)]),
    .testTarget(name: "LilArtCoreTests", dependencies: ["LilArtCore"],
                swiftSettings: [.swiftLanguageMode(.v5)]),
  ]
)
