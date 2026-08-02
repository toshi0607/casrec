// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CasRec",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "CasRec", targets: ["CasRec"])
    ],
    targets: [
        .executableTarget(
            name: "CasRec",
            path: "Sources/CasRec"
        )
    ]
)
