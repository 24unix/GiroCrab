// Render the macOS app icon from the master artwork into the standard macOS
// icon grid: an 824x824 squircle centred in a 1024x1024 canvas (100 px margin),
// with a fully transparent alpha channel outside the squircle. Icons that do
// not follow this shape (opaque corners, art sticking out of the plate) are
// put into a grey fallback plate by macOS (Finder, Dock, disk image window).
//
// Usage: swift scripts/make-app-icon.swift <master.png> <out-dir> [--iconset]
//   default    writes icon-{16,32,64,128,256,512,1024}.png (asset catalog names)
//   --iconset  writes icon_NxN.png / icon_NxN@2x.png for `iconutil -c icns`
//
// The master artwork may carry its own (differently shaped) background plate:
// the squircle is filled with PLATE_COLOR first and the art is scaled by
// ART_SCALE around the centre, so nothing of it is clipped by the squircle.
// Every output is verified (outside the squircle alpha == 0, inside == 255).
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let canvas = 1024
let plateRGB: [CGFloat] = [42 / 255, 54 / 255, 75 / 255]  // #2A364B, the master's plate colour
let artScale: CGFloat = 0.80

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("make-app-icon: \(msg)\n".utf8))
    exit(1)
}

// macOS squircle (same outline as GiroCrabApp/Assets/girocrab-icon.svg), in a
// top-left-origin 1024 space; `s` scales it to the output size.
func squircle(scale s: CGFloat) -> CGPath {
    let p = CGMutablePath()
    func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * s, y: y * s) }
    p.move(to: pt(285, 100))
    p.addLine(to: pt(739, 100))
    p.addCurve(to: pt(924, 285), control1: pt(869.78464, 100), control2: pt(924, 154.21536))
    p.addLine(to: pt(924, 739))
    p.addCurve(to: pt(739, 924), control1: pt(924, 869.78464), control2: pt(869.78464, 924))
    p.addLine(to: pt(285, 924))
    p.addCurve(to: pt(100, 739), control1: pt(154.21536, 924), control2: pt(100, 869.78464))
    p.addLine(to: pt(100, 285))
    p.addCurve(to: pt(285, 100), control1: pt(100, 154.21536), control2: pt(154.21536, 100))
    p.closeSubpath()
    return p
}

// Render in the master's own colour space (an untagged PNG would otherwise be
// colour-converted, and the art's plate would no longer match the fill colour).
var space = CGColorSpace(name: CGColorSpace.sRGB)!

func makeContext(_ size: Int) -> CGContext {
    guard let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
        space: space,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fail("cannot create \(size)px context") }
    // top-left origin, like the SVG / pixel coordinates
    ctx.translateBy(x: 0, y: CGFloat(size))
    ctx.scaleBy(x: 1, y: -1)
    ctx.interpolationQuality = .high
    return ctx
}

func render(_ art: CGImage, size: Int) -> CGImage {
    let ctx = makeContext(size)
    let s = CGFloat(size) / CGFloat(canvas)
    ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))
    ctx.addPath(squircle(scale: s))
    ctx.clip()
    ctx.setFillColor(CGColor(colorSpace: space, components: plateRGB + [1])!)
    ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
    let side = CGFloat(size) * artScale
    let origin = (CGFloat(size) - side) / 2
    // draw(_:in:) expects a bottom-left origin: flip locally around the rect
    ctx.saveGState()
    ctx.translateBy(x: 0, y: origin * 2 + side)
    ctx.scaleBy(x: 1, y: -1)
    ctx.draw(art, in: CGRect(x: origin, y: origin, width: side, height: side))
    ctx.restoreGState()
    guard let img = ctx.makeImage() else { fail("render \(size)px failed") }
    return img
}

/// Alpha must be 0 outside the squircle and 255 inside (antialiased edge of
/// ~1.5 px excluded).
func verify(_ img: CGImage, size: Int) {
    let ctx = makeContext(size)
    ctx.draw(img, in: CGRect(x: 0, y: 0, width: size, height: size))
    guard let data = ctx.data else { fail("verify: no pixel data") }
    let px = data.bindMemory(to: UInt8.self, capacity: size * size * 4)
    let s = CGFloat(size) / CGFloat(canvas)
    let shape = squircle(scale: s)
    let edge = max(1.5, s * 2)
    let outer = shape.copy(strokingWithWidth: edge * 2, lineCap: .butt, lineJoin: .miter, miterLimit: 10)
    var bad = 0
    for y in 0..<size {
        for x in 0..<size {
            let c = CGPoint(x: CGFloat(x) + 0.5, y: CGFloat(y) + 0.5)
            if outer.contains(c) { continue }  // antialiased border
            // pixel memory is bottom-up after the flip in makeContext
            let a = px[((size - 1 - y) * size + x) * 4 + 3]
            if shape.contains(c) ? a != 255 : a != 0 { bad += 1 }
        }
    }
    if bad > 0 { fail("\(size)px: \(bad) pixels violate the squircle alpha mask") }
}

func writePNG(_ img: CGImage, to url: URL) {
    guard let dst = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fail("cannot write \(url.path)") }
    CGImageDestinationAddImage(dst, img, nil)
    guard CGImageDestinationFinalize(dst) else { fail("cannot write \(url.path)") }
}

let args = Array(CommandLine.arguments.dropFirst())
let iconset = args.contains("--iconset")
let paths = args.filter { $0 != "--iconset" }
guard paths.count == 2 else {
    fail("usage: swift scripts/make-app-icon.swift <master.png> <out-dir> [--iconset]")
}
let srcURL = URL(fileURLWithPath: paths[0])
let outDir = URL(fileURLWithPath: paths[1], isDirectory: true)
guard let src = CGImageSourceCreateWithURL(srcURL as CFURL, nil),
      let art = CGImageSourceCreateImageAtIndex(src, 0, nil)
else { fail("cannot read \(srcURL.path)") }
if let cs = art.colorSpace, cs.model == .rgb { space = cs }
guard art.width == art.height, art.width >= canvas else {
    fail("master must be square and at least \(canvas)px (got \(art.width)x\(art.height))")
}
try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

var rendered: [Int: CGImage] = [:]
for size in [16, 32, 64, 128, 256, 512, 1024] {
    let img = render(art, size: size)
    verify(img, size: size)
    rendered[size] = img
}
if iconset {
    for base in [16, 32, 128, 256, 512] {
        writePNG(rendered[base]!, to: outDir.appendingPathComponent("icon_\(base)x\(base).png"))
        writePNG(rendered[base * 2]!, to: outDir.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
    }
} else {
    for (size, img) in rendered {
        writePNG(img, to: outDir.appendingPathComponent("icon-\(size).png"))
    }
}
print("make-app-icon: \(rendered.count) sizes verified -> \(outDir.path)")
