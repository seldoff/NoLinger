// swift-tools-version: 6.0
import PackageDescription

// The app is built with Xcode. This package tests quit policy and app selection rules.
let package = Package(
    name: "NoLingerCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "NoLingerCore", targets: ["NoLingerCore"])],
    targets: [
        .target(name: "NoLingerCore", path: "NoLinger",
                exclude: ["AccessibilityProbe.swift", "AutoQuitMonitor.swift",
                          "ContentView.swift", "MyApp.swift", "Assets.xcassets"],
                sources: ["QuitPolicy.swift", "AppModel.swift"]),
        .testTarget(name: "NoLingerCoreTests", dependencies: ["NoLingerCore"], path: "Tests/NoLingerCoreTests")
    ]
)
