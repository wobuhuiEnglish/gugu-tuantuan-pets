// Fades dark grey marks inside a rectangle toward white (for over-dark head tufts).
// usage: lighten <in.png> <out.png> x y w h amount(0..1)
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
let a = CommandLine.arguments
let img = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(URL(fileURLWithPath: a[1]) as CFURL, nil)!, 0, nil)!
let W = img.width, H = img.height
var px = [UInt8](repeating: 0, count: W * H * 4)
let c = CGContext(data: &px, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
c.draw(img, in: CGRect(x: 0, y: 0, width: W, height: H))
let x0 = Int(a[3])!, y0 = Int(a[4])!, w = Int(a[5])!, h = Int(a[6])!, k = Double(a[7])!
// Target = the surrounding fur colour (average of the light pixels in the box), not pure white.
var fur = [0.0, 0, 0], n = 0.0
for y in y0..<min(H, y0 + h) { for x in x0..<min(W, x0 + w) {
    let i = (y * W + x) * 4
    let l = 0.3 * Double(px[i]) + 0.59 * Double(px[i+1]) + 0.11 * Double(px[i+2])
    if px[i+3] > 230 && l > 220 { for ch in 0..<3 { fur[ch] += Double(px[i+ch]) }; n += 1 }
}}
if n > 0 { for ch in 0..<3 { fur[ch] /= n } }
for y in y0..<min(H, y0 + h) { for x in x0..<min(W, x0 + w) {
    let i = (y * W + x) * 4
    let r = Double(px[i]), g = Double(px[i+1]), b = Double(px[i+2]), al = Double(px[i+3])
    let l = 0.3 * r + 0.59 * g + 0.11 * b
    guard al > 230, max(r, g, b) - min(r, g, b) < 30, l < 220 else { continue }
    for ch in 0..<3 { px[i+ch] = UInt8(Double(px[i+ch]) + (fur[ch] - Double(px[i+ch])) * k) }
}}
let o = c.makeImage()!
let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: a[2]) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(d, o, nil); CGImageDestinationFinalize(d)
