import AppKit
import CoreGraphics
import SwiftUI

// Run with `swift Scripts/generate-app-icon.swift` from the project root.
// An optional argument selects a different output AppIcon.appiconset directory.
@MainActor
func generateAppIcon() throws {
    let projectRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let output = CommandLine.arguments.dropFirst().first.map { URL(fileURLWithPath: $0) }
        ?? projectRoot.appendingPathComponent("NoLinger/Assets.xcassets/AppIcon.appiconset")
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

    // Match ContentView's header styling with a larger symbol for the app icon.
    // A white underlay preserves the pale lavender tile against any Dock background.
    let badge = Image(systemName: "door.left.hand.open")
        .font(.system(size: 35, weight: .medium))
        .foregroundStyle(.indigo)
        .frame(width: 52, height: 52)
        .background(.indigo.opacity(0.1), in: RoundedRectangle(cornerRadius: 13))
        .background(.white, in: RoundedRectangle(cornerRadius: 13))
        .padding(6)
        .environment(\.colorScheme, .light)
    let renderer = ImageRenderer(content: badge)
    renderer.scale = 16
    renderer.proposedSize = ProposedViewSize(width: 64, height: 64)
    guard let master = renderer.cgImage else {
        throw NSError(domain: "NoLinger.AppIcon", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "Could not render the app header icon."])
    }
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    for pixels in [16, 32, 64, 128, 256, 512, 1024] {
        let bitmap = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8,
                               bytesPerRow: 0, space: space,
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        bitmap.interpolationQuality = .high
        bitmap.draw(master, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))
        let representation = NSBitmapImageRep(cgImage: bitmap.makeImage()!)
        let png = representation.representation(using: .png, properties: [:])!
        try png.write(to: output.appendingPathComponent("icon-\(pixels).png"))
    }

    let slots: [(Int, Int)] = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2),
                              (256, 1), (256, 2), (512, 1), (512, 2)]
    let contents: [String: Any] = [
        "images": slots.map { size, scale in
            ["filename": "icon-\(size * scale).png", "idiom": "mac", "scale": "\(scale)x", "size": "\(size)x\(size)"]
        },
        "info": ["author": "xcode", "version": 1]
    ]
    let json = try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    try json.write(to: output.appendingPathComponent("Contents.json"))
    print("Generated macOS app icon sizes in \(output.path)")
}

try MainActor.assumeIsolated { try generateAppIcon() }
