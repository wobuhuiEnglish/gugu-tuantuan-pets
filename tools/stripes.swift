// Copies tabby stripes from one frame's forehead onto another frame of the same sheet,
// darken-only, so the base fur colour and outlines of the target stay untouched.
// usage: stripes <sheet.png> <out.png> srcX srcY dstX dstY w h scaleY
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let a = CommandLine.arguments
let img = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(URL(fileURLWithPath: a[1]) as CFURL, nil)!, 0, nil)!
let W = img.width, H = img.height
var px = [UInt8](repeating: 0, count: W * H * 4)
let ctx = CGContext(data: &px, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(img, in: CGRect(x: 0, y: 0, width: W, height: H))
let sx = Int(a[3])!, sy = Int(a[4])!, dx = Int(a[5])!, dy = Int(a[6])!, w = Int(a[7])!, h = Int(a[8])!
let scaleY = Double(a[9])!
func lum(_ i: Int) -> Double { 0.3 * Double(px[i]) + 0.59 * Double(px[i+1]) + 0.11 * Double(px[i+2]) }
func isFur(_ i: Int) -> Bool {          // mid grey, low saturation: tabby base coat, not white/outline/pink/cyan
    let r = Int(px[i]), g = Int(px[i+1]), b = Int(px[i+2])
    let l = lum(i)
    return l > 140 && l < 222 && max(r, g, b) - min(r, g, b) < 28
}
// Base coat brightness of the source area = upper quartile of its fur pixels.
var furL: [Double] = []
for y in 0..<Int(Double(h) / scaleY) { for x in 0..<w {
    let i = ((sy + y) * W + sx + x) * 4
    if isFur(i) || lum(i) < 170 { furL.append(lum(i)) }
}}
furL.sort()
let base = furL.isEmpty ? 190 : furL[furL.count * 3 / 4]
var out = px
for y in 0..<h { for x in 0..<w {
    let di = ((dy + y) * W + dx + x) * 4
    guard isFur(di) else { continue }
    let srcY = sy + Int(Double(y) / scaleY), srcX = sx + x
    let si = (srcY * W + srcX) * 4
    let l = lum(si)
    let r = Int(px[si]), g = Int(px[si+1]), b = Int(px[si+2])
    guard max(r, g, b) - min(r, g, b) < 40, l < base else { continue }   // only grey stripe pixels
    // Feather the patch edges so no seam shows.
    let ex = min(Double(x), Double(w - 1 - x)) / 6, ey = min(Double(y), Double(h - 1 - y)) / 6
    let feather = min(1, min(ex, ey))
    let f = 1 - (1 - max(0.55, l / base)) * feather
    for c in 0..<3 { out[di + c] = UInt8(Double(px[di + c]) * f) }
}}
let octx = CGContext(data: &out, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                     space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: a[2]) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(d, octx.makeImage()!, nil); CGImageDestinationFinalize(d)
print("base", Int(base))
