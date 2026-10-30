// swift-tools-version: 6.1
import Foundation
import PackageDescription

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let runtimeVersion = try String(contentsOf: root.appendingPathComponent("VERSION"), encoding: .utf8)
  .trimmingCharacters(in: .whitespacesAndNewlines)

let package = Package(
  name: "VoIPSDK",
  platforms: [.iOS("17.4"), .macOS(.v13)],
  products: [
    .library(name: "VoIPSDK", targets: ["VoIPSDK"]),
    .library(name: "VoIPSDKTesting", targets: ["VoIPSDKTesting"]),
  ],
  targets: [
    .target(name: "CKSimProtocol"),
    .target(
      name: "CKSimRuntimeC",
      path: "Sources/Interposition",
      exclude: ["CKLoader.m"],
      publicHeadersPath: "include",
      cSettings: [
        .define("CKSIM_SDK_SOURCE", to: "1"),
        .define("CKSIM_RUNTIME_VERSION", to: "\"\(runtimeVersion)\""),
      ]
    ),
    .target(
      name: "CKSimRuntime",
      dependencies: ["CKSimRuntimeC", "CKSimProtocol"],
      path: "Sources/Engine",
      exclude: ["Resources"]
    ),
    .target(
      name: "VoIPPlatform", path: "Sources/VoIPPlatform", publicHeadersPath: "include",
      cSettings: [
        .define("DEBUG", to: "1", .when(configuration: .debug))
      ]),
    .target(
      name: "VoIPSDK", dependencies: ["CKSimRuntime", "VoIPPlatform"], path: "Sources/VoIPSDK",
      cSettings: [
        .define("DEBUG", to: "1", .when(configuration: .debug))
      ]),
    .target(name: "VoIPSDKTesting"),
    .testTarget(name: "VoIPSDKTests", dependencies: ["VoIPSDK", "VoIPSDKTesting"]),
    .testTarget(name: "VoIPSDKTestingTests", dependencies: ["VoIPSDKTesting"]),
    .testTarget(name: "RuntimeEngineTests", dependencies: ["CKSimRuntime"]),
    .testTarget(name: "CKSimProtocolTests", dependencies: ["CKSimProtocol"]),
  ],
  swiftLanguageModes: [.v6]
)
