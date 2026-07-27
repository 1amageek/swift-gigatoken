// swift-tools-version: 6.4

import PackageDescription

let package = Package(
  name: "swift-gigatoken",
  platforms: [
    .macOS(.v26),
    .iOS(.v26),
  ],
  products: [
    .library(name: "GigaTokenCore", targets: ["GigaTokenCore"]),
    .library(name: "GigaToken", targets: ["GigaToken"]),
    .executable(name: "gigatoken-benchmark", targets: ["GigaTokenBenchmark"]),
  ],
  dependencies: [
    .package(
      url: "https://github.com/1amageek/swift-vector-kernels.git",
      exact: "0.1.0"
    ),
  ],
  targets: [
    .target(
      name: "GigaTokenCore",
      dependencies: [
        .product(name: "VectorKernels", package: "swift-vector-kernels"),
        .product(name: "VectorKernelsNative", package: "swift-vector-kernels"),
      ],
      swiftSettings: [.enableExperimentalFeature("Lifetimes")]
    ),
    .target(
      name: "GigaToken",
      dependencies: ["GigaTokenCore"]
    ),
    .executableTarget(
      name: "GigaTokenSmoke",
      dependencies: ["GigaTokenCore"],
      path: "Tests/GigaTokenSmoke",
      linkerSettings: [
        .linkedLibrary("c++abi", .when(platforms: [.wasi]))
      ]
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
