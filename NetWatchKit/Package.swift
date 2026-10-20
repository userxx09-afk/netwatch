// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "NetWatchKit",
    platforms: [.iOS(.v16)],
    products: [
        .library(name: "NetWatchKit", targets: ["NetWatchKit"]),
    ],
    targets: [
        .target(name: "NetWatchKit", path: "Sources/NetWatchKit"),
    ]
)
