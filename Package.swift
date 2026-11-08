// swift-tools-version:5.9
import Foundation
import PackageDescription

// Paths are resolved from this file so the package builds from any working directory.
let repoRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path

let package = Package(
  name: "friday",
  // Matches the deployment target the previous swiftc build produced. Lowering it hides
  // the AVAudioEngine deprecations, because they only fire at or above macOS 27.
  platforms: [.macOS("27.0")],
  targets: [
    // One module: the daemon-facing code and the pure logic compile together, so tests
    // reach the logic with @testable import instead of the library needing public API it
    // does not otherwise want.
    .executableTarget(
      name: "friday",
      path: "Sources",
      sources: ["friday", "FridayCore"],
      swiftSettings: [
        // Hand-written module interface for the private framework; there is no module map.
        .unsafeFlags(["-I", repoRoot + "/interfaces"])
      ],
      linkerSettings: [
        .unsafeFlags([
          "-F", "/System/Library/PrivateFrameworks",
          "-Xlinker", "-weak_framework", "-Xlinker", "SiriTTSService",
          // The daemon only treats the client as entitled when the Info.plist travels
          // inside __TEXT rather than beside the binary.
          "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT",
          "-Xlinker", "__info_plist", "-Xlinker", repoRoot + "/info.plist",
        ])
      ]
    ),
    // The test target also needs the interface path: importing the module requires the
    // compiler to resolve the private framework it references.
    .testTarget(
      name: "FridayTests",
      dependencies: ["friday"],
      swiftSettings: [.unsafeFlags(["-I", repoRoot + "/interfaces"])]
    ),
  ]
)
