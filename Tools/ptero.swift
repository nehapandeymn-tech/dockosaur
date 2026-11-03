// Draws the pterodactyl sheet (5 wing frames x 2 colours, 32x32, facing left) in the dino's
// pixel style: 1 px dark outline, two body tones, cream wing membrane, white eye.
//   swift Tools/ptero.swift Resources/Art/ptero.png
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "Resources/Art/ptero.png"
let N = 32

// Palette slots: 0 empty, 1 outline, 2 body dark, 3 body light, 4 membrane, 5 membrane shade, 6 eye, 7 crest, 8 beak
typealias RGB = (UInt8, UInt8, UInt8)
let palettes: [[RGB]] = [
    // purple, red crest
    [(0, 0, 0), (0x2b, 0x1d, 0x3a), (0x6e, 0x48, 0x9c), (0x93, 0x68, 0xc8), (0xff, 0xd7, 0xa8), (0xd8, 0xb7, 0x8f),
     (0xff, 0xff, 0xff), (0xc4, 0x3f, 0x31), (0xe8, 0xd6, 0xa6)],
    // rust orange, teal crest
    [(0, 0, 0), (0x3a, 0x22, 0x14), (0xa8, 0x55, 0x24), (0xd4, 0x7e, 0x3a), (0xff, 0xe3, 0xb8), (0xe0, 0xbc, 0x8a),
     (0xff, 0xff, 0xff), (0x3f, 0xa7, 0xc4), (0xe8, 0xd6, 0xa6)],
]

struct Grid {
    var c = [Int](repeating: 0, count: N * N)
    subscript(x: Int, y: Int) -> Int {
        get { x >= 0 && y >= 0 && x < N && y < N ? c[y * N + x] : 0 }
        set { if x >= 0 && y >= 0 && x < N && y < N { c[y * N + x] = newValue } }
    }
    mutating func ellipse(_ cx: Double, _ cy: Double, _ rx: Double, _ ry: Double, _ v: Int) {
        for y in 0..<N { for x in 0..<N {
            let dx = (Double(x) + 0.5 - cx) / rx, dy = (Double(y) + 0.5 - cy) / ry
            if dx * dx + dy * dy <= 1 { self[x, y] = v }
        } }
    }
    mutating func poly(_ pts: [(Double, Double)], _ v: Int) {
        for y in 0..<N { for x in 0..<N {
            let px = Double(x) + 0.5, py = Double(y) + 0.5
            var inside = false
            var j = pts.count - 1
            for i in 0..<pts.count {
                let (xi, yi) = pts[i], (xj, yj) = pts[j]
                if (yi > py) != (yj > py), px < (xj - xi) * (py - yi) / (yj - yi) + xi { inside.toggle() }
                j = i
            }
            if inside { self[x, y] = v }
        } }
    }
    mutating func line(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, _ v: Int) {
        let n = Int(max(abs(x1 - x0), abs(y1 - y0)).rounded(.up)) * 2 + 1
        for i in 0...n {
            let t = Double(i) / Double(n)
            self[Int(x0 + (x1 - x0) * t), Int(y0 + (y1 - y0) * t)] = v
        }
    }
    /// Every empty pixel touching ink (8-way) becomes outline.
    mutating func outline() {
        let src = self
        for y in 0..<N { for x in 0..<N where src[x, y] == 0 {
            var touch = false
            for dy in -1...1 { for dx in -1...1 where src[x + dx, y + dy] > 1 { touch = true } }
            if touch { self[x, y] = 1 }
        } }
    }
}

// Wing pose per frame (y grows downward): elbow and tip. 0 = wings high ... 4 = wings low. 2 = level glide.
let poses: [(elbow: (Double, Double), tip: (Double, Double))] = [
    ((14, 6), (20, 1.5)),
    ((15, 10), (25, 5)),
    ((18, 14), (29, 12.5)),
    ((17, 22), (25, 27)),
    ((15, 25), (20, 30)),
]

func frame(_ f: Int) -> Grid {
    var g = Grid()
    let (e, t) = poses[f]
    // Wing membrane: shoulder -> elbow -> tip, trailing edge back to the hip.
    let shoulder = (12.5, 17.0), hip = (20.5, 18.5)
    let trail = ((t.0 + hip.0) / 2 + (f == 2 ? 0 : 1), (t.1 + hip.1) / 2 + (f < 2 ? 2.5 : f == 2 ? 1.5 : -2.5))
    g.poly([shoulder, e, t, trail, hip], 4)
    // membrane shade near the body
    g.poly([shoulder, ((shoulder.0 + e.0) / 2, (shoulder.1 + e.1) / 2), ((hip.0 + trail.0) / 2, (hip.1 + trail.1) / 2), hip], 5)
    // arm bone along the leading edge
    g.line(shoulder.0, shoulder.1, e.0, e.1, 2)
    g.line(e.0, e.1, t.0, t.1, 2)
    // tail with a little vane
    g.line(20, 18.5, 27, 17.5, 2)
    g.poly([(26, 16), (29.5, 17.5), (26, 19)], 3)
    // body
    g.ellipse(16.5, 18.6, 5.6, 2.9, 3)
    g.ellipse(17, 19.6, 4.4, 1.6, 5)           // belly
    // neck + head
    g.ellipse(10.5, 16.4, 3.1, 2.7, 3)
    g.ellipse(11.5, 15.3, 1.8, 1.2, 2)         // brow shade
    // crest sweeping back
    g.poly([(9.5, 14), (18.5, 9.5), (18, 11), (13.5, 15.5)], 7)
    // long beak
    g.poly([(8.5, 15.2), (1.5, 17.4), (8.5, 18.2)], 8)
    g.line(3, 17.5, 8, 17.4, 2)                // mouth line
    // feet tucked under
    g.line(17, 21.5, 19, 22.5, 2)
    g.line(19, 21.5, 21, 22.5, 2)
    // eye
    g[9, 15] = 6; g[10, 15] = 6; g[10, 16] = 1
    g.outline()
    return g
}

let W = N * 6, H = N * 2
var buf = [UInt8](repeating: 0, count: W * H * 4)
for (row, pal) in palettes.enumerated() {
    for f in 0..<5 {
        let g = frame(f)
        for y in 0..<N { for x in 0..<N {
            let v = g[x, y]
            guard v > 0 else { continue }
            let i = ((row * N + y) * W + f * N + x) * 4
            let c = pal[v]
            buf[i] = c.0; buf[i + 1] = c.1; buf[i + 2] = c.2; buf[i + 3] = 255
        } }
    }
}
let ctx = CGContext(data: &buf, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
CGImageDestinationFinalize(dest)
print("wrote \(out)")
