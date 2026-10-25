// Draws the app icon: a white macOS-style rounded tile with the two cats on it.
// usage: icon <cats.png> <out1024.png>
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let a = CommandLine.arguments
let cats = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(URL(fileURLWithPath: a[1]) as CFURL, nil)!, 0, nil)!
let S = 1024
let ctx = CGContext(data: nil, width: S, height: S, bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.interpolationQuality = .high
// Apple's icon grid: 824pt tile centred on a 1024 canvas, corner radius ~185.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let path = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: CGColor(gray: 0, alpha: 0.28))
ctx.addPath(path); ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fillPath()
ctx.restoreGState()
ctx.saveGState()
ctx.addPath(path); ctx.clip()
// ICON_BG="r,g,b,r,g,b" (0-255, top then bottom) tints the tile; default is near-white.
let bg = (ProcessInfo.processInfo.environment["ICON_BG"] ?? "255,255,255,242,242,240").split(separator: ",").map { CGFloat(Double($0)!) / 255 }
let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: [
    CGColor(red: bg[0], green: bg[1], blue: bg[2], alpha: 1), CGColor(red: bg[3], green: bg[4], blue: bg[5], alpha: 1)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(grad, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
// Cats: fill most of the tile width, sit a little below centre like the reference icon's book.
let maxW = Double(ProcessInfo.processInfo.environment["ICON_W"] ?? "760")!
let k = maxW / Double(cats.width)
let w = maxW, h = Double(cats.height) * k
let dy = Double(ProcessInfo.processInfo.environment["ICON_DY"] ?? "-20")!
ctx.draw(cats, in: CGRect(x: 512 - w / 2, y: 512 - h / 2 + dy, width: w, height: h))
ctx.restoreGState()
let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: a[2]) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(d, ctx.makeImage()!, nil); CGImageDestinationFinalize(d)
