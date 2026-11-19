// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "HostAudioGuard",
  platforms: [.macOS(.v15)],
  targets: [
    .executableTarget(name: "HostAudioGuard"),
    .testTarget(name: "HostAudioGuardTests", dependencies: ["HostAudioGuard"]),
  ]
)
