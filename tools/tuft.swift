// Stamps Tuantuan's dark head tuft (taken from a finished frame) onto another frame.
// Darken-only and only over light fur, so outlines, eyes and ears are left alone.
// usage: tuft <src.png> sx sy sw sh <dst.png> <out.png> dx dy scale [angleDeg]
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

func load(_ p: String) -> (CGImage, [UInt8]) {
    let img = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil)!, 0, nil)!
    var px = [UInt8](repeating: 0, count: img.width * img.height * 4)
    let c = CGContext(data: &px, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    return (img, px)
}
let a = CommandLine.arguments
let (si, sp) = load(a[1])
let sx = Double(a[2])!, sy = Double(a[3])!, sw = Double(a[4])!, sh = Double(a[5])!
let (di, dp0) = load(a[6]); var dp = dp0
let dx = Double(a[8])!, dy = Double(a[9])!, scale = Double(a[10])!
let ang = (a.count > 11 ? Double(a[11])! : 0) * .pi / 180
let SW = si.width, DW = di.width, DH = di.height
let ow = sw * scale, oh = sh * scale
for y in 0..<Int(oh.rounded(.up)) { for x in 0..<Int(ow.rounded(.up)) {
    // rotate around the patch centre
    let cx = Double(x) - ow / 2, cy = Double(y) - oh / 2
    let rx = cx * cos(ang) + cy * sin(ang) + ow / 2, ry = -cx * sin(ang) + cy * cos(ang) + oh / 2
    let tx = Int(dx + Double(x)), ty = Int(dy + Double(y))
    guard tx >= 0, ty >= 0, tx < DW, ty < DH else { continue }
    let ux = Int(sx + rx / scale), uy = Int(sy + ry / scale)
    guard ux >= Int(sx), uy >= Int(sy), ux < Int(sx + sw), uy < Int(sy + sh) else { continue }
    let s = (uy * SW + ux) * 4
    let r = Double(sp[s]), g = Double(sp[s+1]), b = Double(sp[s+2]), al = Double(sp[s+3])
    guard al > 200 else { continue }
    let l = 0.3 * r + 0.59 * g + 0.11 * b
    guard max(r, g, b) - min(r, g, b) < 30 else { continue }      // grey/black streaks only
    let dark = max(0, (225 - l) / 225)                             // 0 on white fur, ~1 on black
    guard dark > 0.08 else { continue }
    let t = (ty * DW + tx) * 4
    let tl = 0.3 * Double(dp[t]) + 0.59 * Double(dp[t+1]) + 0.11 * Double(dp[t+2])
    guard dp[t+3] > 230, tl > 195 else { continue }                // only onto light fur
    let f = 1 - dark * (Double(ProcessInfo.processInfo.environment["TUFT_K"] ?? "0.92") ?? 0.92)
    for c in 0..<3 { dp[t + c] = UInt8(Double(dp[t + c]) * f) }
}}
let o = CGContext(data: &dp, width: DW, height: DH, bitsPerComponent: 8, bytesPerRow: DW * 4,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: a[7]) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(d, o.makeImage()!, nil); CGImageDestinationFinalize(d)
