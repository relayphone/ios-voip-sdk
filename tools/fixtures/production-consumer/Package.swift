// swift-tools-version: 6.4
import PackageDescription

let package = Package(
  name: "ProductionConsumer",
  platforms: [.iOS(.v26), .macOS(.v26)],
  dependencies: [.package(name: "VoIPSDK", path: "../../..")],
  targets: [
    .target(
      name: "Consumer",
      dependencies: [
        "VoIPCore", "VoIPAudio", "VoIPFocus", "VoIPLiveActivity",
        "VoIPLiveCommunicationKit", "VoIPPushKit", "VoIPNotifications", "VoIPSimulator",
      ].map { .product(name: $0, package: "VoIPSDK") })
  ]
)
