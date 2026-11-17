// Turns Resources/icon-source.png (the pufferfish on a transparent
// background) into Resources/AppIcon.icns: draws a teal rounded square on
// Apple's icon grid (824pt shape on a 1024pt canvas), sets the fish on it
// with a soft shadow, and renders every size iconutil needs.
//
//   swift scripts/make-icon.swift   (run from the repo root)
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

/// Background gradient, top-left to bottom-right.
let backgroundTop: [CGFloat] = [0.06, 0.55, 0.66, 1]
let backgroundBottom: [CGFloat] = [0.10, 0.76, 0.67, 1]
/// How much of the rounded square's width the fish spans.
let fishScale: CGFloat = 0.80

let sourceURL = URL(fileURLWithPath: "Resources/icon-source.png")
guard let imageSource = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let fish = CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
else { fail("cannot read \(sourceURL.path)") }

let space = CGColorSpace(name: CGColorSpace.sRGB)!
let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue

func master(size: Int) -> CGImage {
    let canvas = CGFloat(size)
    let unit = canvas / 1024
    let shape = CGRect(x: 100 * unit, y: 100 * unit, width: 824 * unit, height: 824 * unit)
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                            bytesPerRow: 0, space: space, bitmapInfo: bitmapInfo)!
    context.interpolationQuality = .high

    // Background.
    context.saveGState()
    context.addPath(CGPath(roundedRect: shape, cornerWidth: shape.width * 0.2237,
                           cornerHeight: shape.width * 0.2237, transform: nil))
    context.clip()
    let gradient = CGGradient(colorSpace: space, colorComponents: backgroundTop + backgroundBottom,
                              locations: [0, 1], count: 2)!
    context.drawLinearGradient(gradient, start: CGPoint(x: shape.minX, y: shape.maxY),
                               end: CGPoint(x: shape.maxX, y: shape.minY), options: [])
    context.restoreGState()

    // Fish, centred, keeping its proportions.
    let width = shape.width * fishScale
    let height = width * CGFloat(fish.height) / CGFloat(fish.width)
    let frame = CGRect(x: shape.midX - width / 2, y: shape.midY - height / 2, width: width, height: height)
    context.setShadow(offset: CGSize(width: 0, height: -14 * unit), blur: 28 * unit,
                      color: CGColor(colorSpace: space, components: [0, 0.18, 0.22, 0.35]))
    context.draw(fish, in: frame)
    return context.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fail("cannot write \(url.path)") }
    CGImageDestinationAddImage(destination, image, nil)
    if !CGImageDestinationFinalize(destination) { fail("cannot write \(url.path)") }
}

let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("Puffer-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: iconset) }

for points in [16, 32, 128, 256, 512] {
    writePNG(master(size: points), to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    writePNG(master(size: points * 2), to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Resources/AppIcon.icns"]
try iconutil.run()
iconutil.waitUntilExit()
if iconutil.terminationStatus != 0 { fail("iconutil failed") }
print("wrote Resources/AppIcon.icns")
