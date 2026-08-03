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
        ),
        // Run with `make test`, not `swift test`: this machine has no Xcode, and the
        // Command Line Tools ship Swift Testing without telling SwiftPM where it is.
        // See the Makefile for the search paths that have to be supplied.
        .testTarget(
            name: "CasRecTests",
            dependencies: ["CasRec"],
            path: "Tests/CasRecTests"
        ),
    ]
)
