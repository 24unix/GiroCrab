// Renders Assets/girocrab-icon.svg (1024×1024, transparent margin) into all
// AppIcon.appiconset PNG sizes with full alpha. Usage:
//   swift Tools/render-icon.swift Assets/girocrab-icon.svg Xcode/App/Assets.xcassets/AppIcon.appiconset
import AppKit

let args = CommandLine.arguments
guard args.count >= 3, let svg = NSImage(contentsOf: URL(fileURLWithPath: args[1])) else {
    FileHandle.standardError.write("cannot load SVG (needs macOS 14+ NSImage SVG support)\n".data(using: .utf8)!)
    exit(1)
}
let out = URL(fileURLWithPath: args[2])
for px in [16, 20, 29, 32, 40, 58, 60, 64, 76, 80, 87, 120, 128, 152, 167, 180, 256, 512, 1024] {
    guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                                     hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { exit(2) }
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    ctx.imageInterpolation = .high
    NSColor.clear.set()
    NSRect(x: 0, y: 0, width: px, height: px).fill(using: .copy)
    svg.draw(in: NSRect(x: 0, y: 0, width: px, height: px), from: .zero, operation: .sourceOver, fraction: 1)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("icon-\(px).png"))
}
print("rendered icons to \(out.path)")
