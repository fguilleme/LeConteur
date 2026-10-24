// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "ConteurQwen",
    platforms: [.iOS(.v18), .macOS(.v14)],
    products: [.library(name: "ConteurQwen", targets: ["ConteurQwen"])],
    dependencies: [
        .package(url: "https://github.com/Blaizzy/mlx-audio-swift.git", revision: "d8e2cafea891928075d3c8577b1a05b99396594e"),
        .package(url: "https://github.com/ml-explore/mlx-swift.git", exact: "0.32.3"),
        .package(url: "https://github.com/huggingface/swift-transformers.git", exact: "1.1.6"),
    ],
    targets: [.target(name: "ConteurQwen", dependencies: [
        .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
        .product(name: "MLXAudioCodecs", package: "mlx-audio-swift"),
        .product(name: "MLX", package: "mlx-swift"),
        .product(name: "MLXNN", package: "mlx-swift"),
        .product(name: "MLXFast", package: "mlx-swift"),
        .product(name: "Tokenizers", package: "swift-transformers"),
    ])]
)
