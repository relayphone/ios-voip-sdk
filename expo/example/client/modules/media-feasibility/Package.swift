// swift-tools-version: 6.4
import PackageDescription

let strict: [SwiftSetting] = [
  .treatAllWarnings(as: .error), .enableUpcomingFeature("ExistentialAny"),
  .enableUpcomingFeature("InternalImportsByDefault"),
  .enableUpcomingFeature("MemberImportVisibility"),
]
let package = Package(
  name: "MediaJourneyProtocolTests", platforms: [.macOS(.v26)],
  targets: [
    .target(
      name: "MediaJourneyProtocol", path: "ios",
      exclude: [
        "MediaFeasibilitySubscriber.swift", "MediaFeasibility.podspec", "MediaSyntheticVideo.swift",
      ],
      sources: [
        "MediaJourneyProtocol.swift", "MediaVideoEvidence.swift", "MediaVideoPolicy.swift",
      ], swiftSettings: strict),
    .testTarget(
      name: "ProtocolTests", dependencies: ["MediaJourneyProtocol"], path: "tests/ProtocolTests",
      swiftSettings: strict),
  ], swiftLanguageModes: [.v6])
