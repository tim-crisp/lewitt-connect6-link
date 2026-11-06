import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

guard CommandLine.arguments.count == 2 else { fatalError("Usage: generate-icon.swift OUTPUT.iconset") }
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

// Original vector artwork; no downloaded assets, fonts or vendor logos.
func render(size: Int, name: String) throws {
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.scaleBy(x: CGFloat(size) / 1024, y: CGFloat(size) / 1024)
    context.setFillColor(CGColor(red: 0.13, green: 0.17, blue: 0.16, alpha: 1))
    context.addPath(CGPath(roundedRect: CGRect(x: 64, y: 64, width: 896, height: 896),
                           cornerWidth: 200, cornerHeight: 200, transform: nil))
    context.fillPath()
    context.translateBy(x: 512, y: 512)
    context.rotate(by: -.pi / 4)
    context.setStrokeColor(CGColor(red: 0.45, green: 0.9, blue: 0.44, alpha: 1))
    context.setLineWidth(62)
    for x in [-200.0, -20.0] {
        context.addPath(CGPath(roundedRect: CGRect(x: x, y: -130, width: 220, height: 390),
                               cornerWidth: 110, cornerHeight: 110, transform: nil))
        context.strokePath()
    }
    let file = output.appendingPathComponent(name)
    guard let image = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(file as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { throw CocoaError(.fileWriteUnknown) }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
}
for points in [16, 32, 128, 256, 512] {
    try render(size: points, name: "icon_\(points)x\(points).png")
    try render(size: points * 2, name: "icon_\(points)x\(points)@2x.png")
}
