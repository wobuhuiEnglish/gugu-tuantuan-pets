// Pastes a head (src rect) onto dst, scaled, with a soft elliptical edge.
// Pixels right of `xlimit` in dst are left alone so the head tucks behind the other cat.
// usage: headswap <src.png> sx sy sw sh <dst.png> <out.png> dx dy scale xlimit
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
func load(_ p: String) -> (Int, Int, [UInt8]) {
    let img = CGImageSourceCreateImageAtIndex(CGImageSourceCreateWithURL(URL(fileURLWithPath: p) as CFURL, nil)!, 0, nil)!
    var px = [UInt8](repeating: 0, count: img.width * img.height * 4)
    let c = CGContext(data: &px, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.interpolationQuality = .high
    c.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
    return (img.width, img.height, px)
}
let a = CommandLine.arguments
let (SW, _, sp) = load(a[1])
let sx = Double(a[2])!, sy = Double(a[3])!, sw = Double(a[4])!, sh = Double(a[5])!
let (DW, DH, dp0) = load(a[6]); var dp = dp0
let dx = Double(a[8])!, dy = Double(a[9])!, k = Double(a[10])!, xlimit = Double(a[11])!
let ow = Int(sw * k), oh = Int(sh * k)
func sample(_ x: Double, _ y: Double) -> [Double] {   // bilinear, premultiplied
    let x0 = Int(x), y0 = Int(y), fx = x - Double(x0), fy = y - Double(y0)
    var r = [0.0, 0, 0, 0]
    for (ox, oy, w) in [(0, 0, (1 - fx) * (1 - fy)), (1, 0, fx * (1 - fy)), (0, 1, (1 - fx) * fy), (1, 1, fx * fy)] {
        let i = ((y0 + oy) * SW + x0 + ox) * 4
        for c in 0..<4 { r[c] += Double(sp[i + c]) * w }
    }
    return r
}
for y in 0..<oh { for x in 0..<ow {
    let tx = Int(dx) + x, ty = Int(dy) + y
    guard tx >= 0, ty >= 0, tx < DW, ty < DH, Double(tx) < xlimit else { continue }
    // soft ellipse: full inside, fades over the outer 15%, mostly at the bottom (neck)
    let ex = (Double(x) - Double(ow) / 2) / (Double(ow) / 2), ey = (Double(y) - Double(oh) * 0.45) / (Double(oh) * 0.55)
    let d = sqrt(ex * ex + ey * ey)
    let soft = ey > 0 ? max(0, min(1, (1.0 - d) / 0.25)) : 1
    let s = sample(sx + Double(x) / k, sy + Double(y) / k)
    let al = s[3] / 255 * soft
    guard al > 0.01 else { continue }
    let t = (ty * DW + tx) * 4
    for c in 0..<3 { dp[t + c] = UInt8(min(255, s[c] * soft + Double(dp[t + c]) * (1 - al))) }
    dp[t + 3] = UInt8(min(255, s[3] * soft + Double(dp[t + 3]) * (1 - al)))
}}
let o = CGContext(data: &dp, width: DW, height: DH, bitsPerComponent: 8, bytesPerRow: DW * 4,
                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let dd = CGImageDestinationCreateWithURL(URL(fileURLWithPath: a[7]) as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dd, o.makeImage()!, nil); CGImageDestinationFinalize(dd)
