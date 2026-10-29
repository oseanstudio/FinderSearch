// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "FinderSearch", platforms: [.macOS("15.0")],
    products: [.executable(name: "FinderSearch", targets: ["FinderSearch"])],
    dependencies: [
        // HOME: embedded terminal — same engine Shark uses.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
    ],
    targets: [
        .executableTarget(
            name: "FinderSearch",
            dependencies: [.product(name: "SwiftTerm", package: "SwiftTerm")]),
        .testTarget(name: "FinderSearchTests", dependencies: ["FinderSearch"]),
    ])
