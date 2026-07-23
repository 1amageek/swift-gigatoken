// swift-tools-version: 6.3

import PackageDescription

let package = Package(
  name: "swift-gigatoken",
  platforms: [
    .macOS(.v26),
    .iOS(.v26),
  ],
  products: [
    .library(name: "SwiftGigaTokenCore", targets: ["SwiftGigaTokenCore"]),
    .library(name: "SwiftGigaToken", targets: ["SwiftGigaToken"]),
    .executable(name: "swift-gigatoken-smoke", targets: ["SwiftGigaTokenSmoke"]),
    .executable(name: "swift-gigatoken-benchmark", targets: ["SwiftGigaTokenBenchmark"]),
  ],
  dependencies: [
    .package(
      path: "../swift-vector-kernels"
    ),
  ],
  targets: [
    .target(
      name: "SwiftGigaTokenCore",
      dependencies: [
        .product(name: "VectorKernels", package: "swift-vector-kernels"),
        .product(name: "VectorKernelsNative", package: "swift-vector-kernels"),
      ]
    ),
    .target(
      name: "SwiftGigaToken",
      dependencies: ["SwiftGigaTokenCore"]
    ),
    .executableTarget(
      name: "SwiftGigaTokenSmoke",
      dependencies: ["SwiftGigaTokenCore"]
    ),
    .executableTarget(
      name: "SwiftGigaTokenBenchmark",
      dependencies: ["SwiftGigaToken", "SwiftGigaTokenCore"]
    ),
    .testTarget(
      name: "SwiftGigaTokenCoreTests",
      dependencies: ["SwiftGigaTokenCore"]
    ),
    .testTarget(
      name: "SwiftGigaTokenTests",
      dependencies: ["SwiftGigaToken", "SwiftGigaTokenCore"],
      resources: [.copy("Fixtures")]
    ),
  ]
)
