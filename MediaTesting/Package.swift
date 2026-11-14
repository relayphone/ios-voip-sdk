// swift-tools-version: 6.4
import PackageDescription

let strictSwift: [SwiftSetting] = [
  .treatAllWarnings(as: .error),
  .enableUpcomingFeature("ExistentialAny"),
  .enableUpcomingFeature("InternalImportsByDefault"),
  .enableUpcomingFeature("MemberImportVisibility"),
]

let package = Package(
  name: "VoIPMediaTesting",
  platforms: [.iOS(.v26), .macOS(.v26)],
  products: [.library(name: "VoIPMediaTesting", targets: ["VoIPMediaTesting"])],
  dependencies: [
    .package(name: "VoIPSDK", path: ".."),
    .package(url: "https://github.com/livekit/client-sdk-swift", exact: "2.19.0"),
  ],
  targets: [
    .target(
      name: "VoIPMediaTesting",
      dependencies: [
        .product(name: "LiveKit", package: "client-sdk-swift", condition: .when(platforms: [.iOS]))
      ], swiftSettings: strictSwift),
    .testTarget(
      name: "VoIPMediaTestingTests",
      dependencies: [
        "VoIPMediaTesting",
        .product(name: "VoIPTesting", package: "VoIPSDK"),
        .product(name: "LiveKit", package: "client-sdk-swift", condition: .when(platforms: [.iOS])),
      ], swiftSettings: strictSwift),
  ],
  swiftLanguageModes: [.v6]
)
