// Cuts an AI-generated sprite grid (cyan background) into transparent frames.
// usage: slice <sheet.png> <cols> <rows> <outDir> <prefix>
// Writes <prefix>-<i>.png (trimmed, transparent) and <prefix>.json with each
// frame's size and foot anchor (bottom edge, centre of the lowest 25% of the body).
import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

let a = CommandLine.arguments
let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: a[1]) as CFURL, nil)!
let img = CGImageSourceCreateImageAtIndex(src, 0, nil)!
let cols = Int(a[2])!, rows = Int(a[3])!
let outDir = a[4], prefix = a[5]
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let W = img.width, H = img.height
var px = [UInt8](repeating: 0, count: W * H * 4)
let ctx = CGContext(data: &px, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.draw(img, in: CGRect(x: 0, y: 0, width: W, height: H))

// "Cyan-ness": how far green and blue sit above red. Background ~ (0..60, 230..255, 230..255).
func keyAlpha(_ r: Int, _ g: Int, _ b: Int) -> Double {
    let c = Double(min(g, b) - r)          // 200+ on cyan, ~0 on white/grey fur
    if c >= 150 { return 0 }
    if c <= 60 { return 1 }
    return 1 - (c - 60) / 90
}

var alpha = [Double](repeating: 0, count: W * H)
for i in 0..<(W * H) {
    alpha[i] = keyAlpha(Int(px[i*4]), Int(px[i*4+1]), Int(px[i*4+2]))
}
// Gemini stamps a small sparkle watermark in the bottom-right corner; it can touch the
// last frame's tail, so blank that corner outright.
// SHADOW=1: also drop soft blue-grey cast shadows the model sometimes paints on the cyan.
if ProcessInfo.processInfo.environment["SHADOW"] == "1" {
    // Only in the lower part of each cell (where the cast shadow sits), and only for
    // clearly shadow-coloured pixels, so cat outlines elsewhere keep their anti-aliasing.
    let rowsN = Int(CommandLine.arguments[3])!, cellH = H / rowsN
    for i in 0..<(W * H) {
        let y = i / W
        guard y % cellH > cellH * 6 / 10 else { continue }
        let r = Int(px[i*4]), g = Int(px[i*4+1]), b = Int(px[i*4+2])
        let l = (r * 3 + g * 6 + b) / 10
        if min(g, b) - r > 25 && l > 120 && l < 225 { alpha[i] = 0 }
    }
}
let mark = max(W, H) * 5 / 100
for y in (H - mark)..<H { for x in (W - mark)..<W { alpha[y * W + x] = 0 } }

struct Frame: Codable { let file: String; let width: Int; let height: Int; let footX: Double; let cellX: Int; let cellY: Int; let bottom: Int }
var frames: [Frame] = []
let cw = W / cols, ch = H / rows
// Sometimes the model draws grid lines between cells despite being asked not to;
// clear a thin strip along every inner cell border so they never stick to a frame.
if cols * rows > 1 {
    for y in 0..<H { for x in 0..<W {
        let dx = x % cw, dy = y % ch
        if (dx < 5 || dx >= cw - 5) && x > 5 && x < W - 5 { alpha[y * W + x] = 0 }
        if (dy < 5 || dy >= ch - 5) && y > 5 && y < H - 5 { alpha[y * W + x] = 0 }
    }}
}

for r in 0..<rows {
    for c in 0..<cols {
        let x0 = c * cw, y0 = r * ch
        // Connected components of solid pixels inside the cell; keep the big ones (drops sparkles/specks).
        var label = [Int](repeating: -1, count: cw * ch)
        var sizes: [Int] = []
        for y in 0..<ch { for x in 0..<cw {
            let gi = (y0 + y) * W + (x0 + x)
            if alpha[gi] < 0.5 || label[y * cw + x] >= 0 { continue }
            let id = sizes.count; var n = 0; var stack = [(x, y)]; label[y * cw + x] = id
            while let (sx, sy) = stack.popLast() {
                n += 1
                for (dx, dy) in [(1,0),(-1,0),(0,1),(0,-1)] {
                    let nx = sx + dx, ny = sy + dy
                    if nx < 0 || ny < 0 || nx >= cw || ny >= ch { continue }
                    if label[ny * cw + nx] >= 0 || alpha[(y0 + ny) * W + (x0 + nx)] < 0.5 { continue }
                    label[ny * cw + nx] = id; stack.append((nx, ny))
                }
            }
            sizes.append(n)
        }}
        guard let biggest = sizes.max() else { continue }
        let keep = Set(sizes.indices.filter { sizes[$0] >= biggest / 20 })
        // Grow the kept mask by 2px so soft anti-aliased edges survive, then cut.
        var mask = [Bool](repeating: false, count: cw * ch)
        for i in 0..<(cw * ch) where label[i] >= 0 && keep.contains(label[i]) { mask[i] = true }
        var grown = mask
        for y in 0..<ch { for x in 0..<cw where mask[y * cw + x] {
            for dy in -2...2 { for dx in -2...2 {
                let nx = x + dx, ny = y + dy
                if nx >= 0 && ny >= 0 && nx < cw && ny < ch { grown[ny * cw + nx] = true }
            }}
        }}
        var minX = cw, minY = ch, maxX = -1, maxY = -1
        for y in 0..<ch { for x in 0..<cw where grown[y * cw + x] && alpha[(y0 + y) * W + (x0 + x)] > 0.02 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        }}
        if maxX < 0 { continue }
        let fw = maxX - minX + 1, fh = maxY - minY + 1
        var out = [UInt8](repeating: 0, count: fw * fh * 4)
        for y in 0..<fh { for x in 0..<fw {
            let cx = minX + x, cy = minY + y
            guard grown[cy * cw + cx] else { continue }
            let gi = (y0 + cy) * W + (x0 + cx)
            let al = alpha[gi]
            if al <= 0.02 { continue }
            var rr = Double(px[gi*4]), gg = Double(px[gi*4+1]), bb = Double(px[gi*4+2])
            // Remove cyan spill: the cats' real colours never have both green and blue
            // well above red, so clamp them down wherever that happens (mostly outlines).
            gg = min(gg, rr + 14); bb = min(bb, rr + 14)
            let o = (y * fw + x) * 4
            out[o] = UInt8(rr * al); out[o+1] = UInt8(gg * al); out[o+2] = UInt8(bb * al); out[o+3] = UInt8(al * 255)
        }}
        // Foot anchor: centre of solid pixels in the lowest quarter.
        var sum = 0.0, cnt = 0.0
        for y in (fh * 3 / 4)..<fh { for x in 0..<fw where out[(y * fw + x) * 4 + 3] > 128 { sum += Double(x); cnt += 1 } }
        let i = frames.count
        let file = "\(prefix)-\(i).png"
        let octx = CGContext(data: &out, width: fw, height: fh, bitsPerComponent: 8, bytesPerRow: fw * 4,
                             space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "\(outDir)/\(file)") as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(d, octx.makeImage()!, nil); CGImageDestinationFinalize(d)
        frames.append(Frame(file: file, width: fw, height: fh, footX: cnt > 0 ? sum / cnt : Double(fw) / 2, cellX: minX, cellY: minY, bottom: maxY))
    }
}
let json = try JSONEncoder().encode(frames)
try json.write(to: URL(fileURLWithPath: "\(outDir)/\(prefix).json"))
print("frames:", frames.count)
