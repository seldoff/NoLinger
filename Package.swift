// swift-tools-version: 6.0
import PackageDescription

// The app is built with Xcode. This package tests window metadata, quit policy, app rules, and log collection.
let package = Package(
    name: "NoLingerCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "NoLingerCore", targets: ["NoLingerCore"])],
    targets: [
        .target(name: "NoLingerCore", path: "NoLinger",
                exclude: ["AccessibilityProbe.swift", "AutoQuitMonitor.swift",
                          "ContentView.swift", "MyApp.swift", "Assets.xcassets"],
                sources: ["QuitPolicy.swift", "AppModel.swift", "DiagnosticLog.swift", "WindowServerSnapshot.swift",
                          "AXNotificationSubscriptions.swift"]),
        .testTarget(name: "NoLingerCoreTests", dependencies: ["NoLingerCore"], path: "Tests/NoLingerCoreTests")
    ]
)
