// swift-tools-version: 6.0
import PackageDescription

// The app is built with Xcode. This package tests only the independent quit policy.
let package = Package(
    name: "NoLingerCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "NoLingerCore", targets: ["NoLingerCore"])],
    targets: [
        .target(name: "NoLingerCore", path: "NoLinger",
                exclude: ["AppModel.swift", "AccessibilityProbe.swift", "AutoQuitMonitor.swift",
                          "ContentView.swift", "MyApp.swift", "Assets.xcassets"],
                sources: ["QuitPolicy.swift"]),
        .testTarget(name: "NoLingerCoreTests", dependencies: ["NoLingerCore"], path: "Tests/NoLingerCoreTests")
    ]
)
