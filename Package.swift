// swift-tools-version: 6.3

import PackageDescription

let package = Package(
  name: "GigaToken",
  platforms: [
    .macOS(.v26),
    .iOS(.v26),
  ],
  products: [
    .library(name: "GigaTokenCore", targets: ["GigaTokenCore"]),
    .library(name: "GigaToken", targets: ["GigaToken"]),
    .executable(name: "gigatoken-smoke", targets: ["GigaTokenSmoke"]),
    .executable(name: "gigatoken-benchmark", targets: ["GigaTokenBenchmark"]),
  ],
  dependencies: [
    .package(
      path: "../swift-vector-kernels"
    ),
  ],
  targets: [
    .target(
      name: "GigaTokenCore",
      dependencies: [
        .product(name: "VectorKernels", package: "swift-vector-kernels"),
        .product(name: "VectorKernelsNative", package: "swift-vector-kernels"),
      ]
    ),
    .target(
      name: "GigaToken",
      dependencies: ["GigaTokenCore"]
    ),
    .executableTarget(
      name: "GigaTokenSmoke",
      dependencies: ["GigaTokenCore"]
    ),
    .executableTarget(
      name: "GigaTokenBenchmark",
      dependencies: ["GigaToken", "GigaTokenCore"]
    ),
    .testTarget(
      name: "GigaTokenCoreTests",
      dependencies: ["GigaTokenCore"]
    ),
    .testTarget(
      name: "GigaTokenTests",
      dependencies: ["GigaToken", "GigaTokenCore"],
      resources: [.copy("Fixtures")]
    ),
  ]
)
