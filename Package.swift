// swift-tools-version: 6.0
import Foundation
import PackageDescription

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let runtimeVersion = try String(contentsOf: root.appendingPathComponent("VERSION"), encoding: .utf8)
  .trimmingCharacters(in: .whitespacesAndNewlines)

let package = Package(
  name: "VoIPSDK",
  platforms: [.iOS("17.4")],
  products: [.library(name: "VoIPSDK", targets: ["VoIPSDK"])],
  targets: [
    .target(
      name: "CKSimRuntimeC",
      path: "Sources/Interposition",
      exclude: ["CKLoader.m"],
      publicHeadersPath: ".",
      cSettings: [
        .define("CKSIM_SDK_SOURCE", to: "1"),
        .define("CKSIM_RUNTIME_VERSION", to: "\"\(runtimeVersion)\"")
      ]
    ),
    .target(
      name: "CKSimRuntime",
      dependencies: ["CKSimRuntimeC"],
      path: "Sources/Engine",
      resources: [.copy("Resources/ios-27.0.json")]
    ),
    .target(name: "VoIPPlatform", path: "Sources/VoIPPlatform", publicHeadersPath: "include"),
    .target(name: "VoIPSDK", dependencies: ["CKSimRuntime", "VoIPPlatform"], path: "Sources/VoIPSDK")
  ],
  swiftLanguageModes: [.v6]
)
