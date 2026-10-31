// swift-tools-version: 6.4
import Foundation
import PackageDescription

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let runtimeVersion = try String(contentsOf: root.appendingPathComponent("VERSION"), encoding: .utf8)
  .trimmingCharacters(in: .whitespacesAndNewlines)

/// Applied to every Swift target. SwiftPM ignores warning settings for remote dependencies.
let strictSwift: [SwiftSetting] = [
  .treatAllWarnings(as: .error),
  .enableUpcomingFeature("ExistentialAny"),
  .enableUpcomingFeature("InternalImportsByDefault"),
  .enableUpcomingFeature("MemberImportVisibility"),
]
let strictC: [CSetting] = [.treatAllWarnings(as: .error)]

let package = Package(
  name: "VoIPSDK",
  platforms: [.iOS(.v26), .macOS(.v26)],
  products: [
    .library(name: "VoIPCore", targets: ["VoIPCore"]),
    .library(name: "VoIPAudio", targets: ["VoIPAudio"]),
    .library(name: "VoIPFocus", targets: ["VoIPFocus"]),
    .library(name: "VoIPLiveCommunicationKit", targets: ["VoIPLiveCommunicationKit"]),
    .library(name: "VoIPPushKit", targets: ["VoIPPushKit"]),
    .library(name: "VoIPNotifications", targets: ["VoIPNotifications"]),
    .library(name: "VoIPSimulator", targets: ["VoIPSimulator"]),
    .library(name: "VoIPTesting", targets: ["VoIPTesting"]),
  ],
  dependencies: [
    // For the `cksim` tool only.
    .package(url: "https://github.com/apple/swift-argument-parser", from: "1.7.0")
  ],
  targets: [
    .target(name: "CKSimProtocol", swiftSettings: strictSwift),
    // `cksim`, which controls the standalone runtime from the host. The library holds the tool so
    // that its tests can import it.
    .target(
      name: "CKSimTool",
      dependencies: [
        "CKSimProtocol",
        .product(
          name: "ArgumentParser", package: "swift-argument-parser",
          condition: .when(platforms: [.macOS])),
      ],
      swiftSettings: strictSwift
    ),
    .executableTarget(name: "cksim", dependencies: ["CKSimTool"], swiftSettings: strictSwift),
    .target(
      name: "CKSimRuntimeC",
      path: "Sources/Interposition",
      exclude: ["CKLoader.m"],
      publicHeadersPath: "include",
      cSettings: strictC + [
        .define("CKSIM_SDK_SOURCE", to: "1"),
        .define("CKSIM_RUNTIME_VERSION", to: "\"\(runtimeVersion)\""),
      ]
    ),
    .target(
      name: "CKSimRuntime",
      dependencies: ["CKSimRuntimeC", "CKSimProtocol"],
      path: "Sources/Engine",
      exclude: ["Resources"],
      swiftSettings: strictSwift
    ),
    // The Inspector app's model: everything but the app's entry point.
    .target(
      name: "CKSimInspector",
      dependencies: ["CKSimProtocol"],
      path: "Inspector",
      exclude: ["InspectorApp.swift"],
      swiftSettings: strictSwift
    ),
    .target(name: "VoIPCore", swiftSettings: strictSwift),
    .target(name: "VoIPAudio", dependencies: ["VoIPCore"], swiftSettings: strictSwift),
    .target(name: "VoIPFocus", swiftSettings: strictSwift),
    .target(
      name: "VoIPLiveCommunicationKit", dependencies: ["VoIPCore"], swiftSettings: strictSwift),
    .target(name: "VoIPPushDelivery", cSettings: strictC),
    .target(
      name: "VoIPPushKit", dependencies: ["VoIPCore", "VoIPPushDelivery"],
      swiftSettings: strictSwift),
    .target(name: "VoIPNotifications", dependencies: ["VoIPCore"], swiftSettings: strictSwift),
    .target(name: "VoIPSimulator", dependencies: ["CKSimRuntime"], swiftSettings: strictSwift),
    .target(
      name: "VoIPTesting", dependencies: ["VoIPCore", "VoIPNotifications"],
      swiftSettings: strictSwift),
    .testTarget(
      name: "VoIPCoreTests", dependencies: ["VoIPCore", "VoIPTesting"], swiftSettings: strictSwift),
    .testTarget(
      name: "VoIPAudioTests", dependencies: ["VoIPAudio", "VoIPCore"], swiftSettings: strictSwift),
    .testTarget(name: "VoIPFocusTests", dependencies: ["VoIPFocus"], swiftSettings: strictSwift),
    .testTarget(
      name: "VoIPLiveCommunicationKitTests", dependencies: ["VoIPLiveCommunicationKit"],
      swiftSettings: strictSwift),
    .testTarget(
      name: "VoIPJourneyTests",
      dependencies: [
        "VoIPCore", "VoIPAudio", "VoIPLiveCommunicationKit", "VoIPPushKit", "VoIPSimulator",
        "VoIPTesting", "CKSimProtocol", "VoIPNotifications",
      ],
      swiftSettings: strictSwift),
    .testTarget(
      name: "VoIPPushKitTests", dependencies: ["VoIPPushKit", "VoIPPushDelivery"],
      swiftSettings: strictSwift),
    .testTarget(
      name: "VoIPNotificationsTests",
      dependencies: ["VoIPCore", "VoIPNotifications", "VoIPTesting"],
      swiftSettings: strictSwift),
    .testTarget(
      name: "VoIPTestingTests", dependencies: ["VoIPTesting"], swiftSettings: strictSwift),
    .testTarget(
      name: "RuntimeEngineTests", dependencies: ["CKSimRuntime"], swiftSettings: strictSwift),
    .testTarget(
      name: "CKSimProtocolTests", dependencies: ["CKSimProtocol"], swiftSettings: strictSwift),
    .testTarget(
      name: "InspectorTests", dependencies: ["CKSimInspector"], swiftSettings: strictSwift),
    .testTarget(
      name: "CKSimToolTests",
      dependencies: [
        "CKSimTool", "CKSimProtocol",
        .product(
          name: "ArgumentParser", package: "swift-argument-parser",
          condition: .when(platforms: [.macOS])),
      ],
      swiftSettings: strictSwift),
    .testTarget(
      name: "RuntimeTests",
      dependencies: ["CKSimRuntime", "CKSimRuntimeC", "CKSimProtocol", "CKSimInspector"],
      swiftSettings: strictSwift),
  ],
  swiftLanguageModes: [.v6]
)
