// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "SSMV",
  platforms: [.macOS(.v13)],
  products: [.executable(name: "SSMV", targets: ["SSMV"])],
  targets: [
    .target(name: "MarkdownCore"),
    .executableTarget(name: "SSMV", dependencies: ["MarkdownCore"]),
    .testTarget(name: "MarkdownCoreTests", dependencies: ["MarkdownCore"]),
    .testTarget(name: "SSMVTests", dependencies: ["SSMV"]),
  ]
)
