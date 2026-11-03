// Dockosaur: an endless runner that lives on top of the macOS Dock.
//
// Art (see README for links and licences):
//   dinos            Arks (@ArksDigital), CC BY 4.0
//   spikes/crates/saw/fruit/dust/font  Pixel Frog, CC0
//   hawks            MoikMellah, CC0
//
// Units: game distances are art pixels ("px"), times are seconds. One px is drawn as
// `scale` points (2 by default), so the art stays crisp on Retina screens.

import Cocoa
import Carbon.HIToolbox
import AVFoundation
import ServiceManagement

// MARK: - Tunables

enum K {
    static let below = 3.0           // strip height under the ground surface (ground line + pebbles)
    static let above = 53.0          // strip height over the ground surface
    static let dinoX = 14.0          // dino frame origin; its body starts 4 px in
    static let jumpV = 215.0         // take-off speed  -> apex ≈ 33 px
    static let gravity = 700.0
    static let releaseV = 80.0       // letting go early caps the upward speed (short hop)
    static let startSpeed = 150.0
    static let maxSpeed = 380.0
    static let accel = 1.6           // px/s gained per second
    static let pxPerPoint = 15.0     // 1 point per 15 px run
    static let fruitBonus = 50.0
    static let highBirdBottom = 21.0 // dino head is ~17 px tall: stay on the ground to pass under
    static let lowBirdBottom = 3.0   // gliders skim the ground: jump them
}

// MARK: - Small helpers

struct RNG {   // SplitMix64: deterministic for snapshots and the self-test
    var s: UInt64
    mutating func next() -> UInt64 {
        s &+= 0x9E3779B97F4A7C15
        var z = s
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func unit() -> Double { Double(next() >> 11) / Double(1 << 53) }
    mutating func range(_ a: Double, _ b: Double) -> Double { a + (b - a) * unit() }
    mutating func int(_ n: Int) -> Int { Int(next() % UInt64(n)) }
}

/// Opaque-pixel map of a sprite frame, row 0 at the bottom (world y grows upward).
struct Mask {
    let w: Int, h: Int
    let bits: [Bool]
    func solid(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < w && y < h && bits[y * w + x] }
    var padBottom: Int { for y in 0..<h { for x in 0..<w where bits[y * w + x] { return y } }; return h }
    var padLeft: Int { for x in 0..<w { for y in 0..<h where bits[y * w + x] { return x } }; return w }
    var isEmpty: Bool { !bits.contains(true) }
    /// Drops the outline ring so grazing a tail or a spike tip doesn't count as a hit.
    func eroded() -> Mask {
        var out = [Bool](repeating: false, count: w * h)
        for y in 0..<h { for x in 0..<w where solid(x, y) {
            out[y * w + x] = solid(x - 1, y) && solid(x + 1, y) && solid(x, y - 1) && solid(x, y + 1)
        } }
        return Mask(w: w, h: h, bits: out)
    }
}

func overlaps(_ a: Mask, _ ax: Int, _ ay: Int, _ b: Mask, _ bx: Int, _ by: Int) -> Bool {
    let x0 = max(ax, bx), x1 = min(ax + a.w, bx + b.w)
    let y0 = max(ay, by), y1 = min(ay + a.h, by + b.h)
    if x0 >= x1 || y0 >= y1 { return false }
    for y in y0..<y1 { for x in x0..<x1 where a.solid(x - ax, y - ay) && b.solid(x - bx, y - by) { return true } }
    return false
}

struct Frame { let image: CGImage; let mask: Mask }

func maskOf(_ img: CGImage) -> Mask {
    let w = img.width, h = img.height
    var buf = [UInt8](repeating: 0, count: w * h * 4)
    buf.withUnsafeMutableBytes { p in
        let ctx = CGContext(data: p.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    }
    var bits = [Bool](repeating: false, count: w * h)
    for y in 0..<h { for x in 0..<w { bits[y * w + x] = buf[((h - 1 - y) * w + x) * 4 + 3] > 40 } }  // memory row 0 = top
    return Mask(w: w, h: h, bits: bits)
}

let artDir: URL = {
    let bundled = Bundle.main.resourceURL!.appendingPathComponent("Art")
    if FileManager.default.fileExists(atPath: bundled.path) { return bundled }
    return URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("Resources/Art")
}()

func loadPNG(_ name: String) -> CGImage {
    let url = artDir.appendingPathComponent(name + ".png")
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { fatalError("missing art: \(url.path)") }
    return img
}

func slice(_ img: CGImage, fw: Int, fh: Int, row: Int = 0, count: Int) -> [Frame] {
    (0..<count).map { i in
        let f = img.cropping(to: CGRect(x: i * fw, y: row * fh, width: fw, height: fh))!
        return Frame(image: f, mask: maskOf(f))
    }
}

// MARK: - Art

let characters: [(id: String, name: String)] = [
    ("vita", "Vita (green)"), ("doux", "Doux (blue)"), ("mort", "Mort (red)"), ("tard", "Tard (yellow)"),
]

final class Art {
    private(set) var dino: [Frame] = []       // 0-3 idle, 4-9 run, 10-12 kick, 13-16 hurt, 17-23 crouch
    private(set) var dinoHit: [Mask] = []
    let shadow = loadPNG("shadow")
    let spike: Frame
    let boxes: [Frame]
    let saw: [Frame]
    let birds: [[Frame]]                      // [grey, brown] x 5 wing frames, facing left
    let birdPadLeft: [Int], birdPadBottom: [Int]
    let fruits: [[Frame]]
    let poof: [CGImage]
    let dust = loadPNG("dust")
    private(set) var glyphs: [Character: (white: CGImage, black: CGImage)] = [:]

    init(character: String) {
        spike = slice(loadPNG("spikes"), fw: 16, fh: 16, count: 1)[0]
        boxes = [slice(loadPNG("box1"), fw: 28, fh: 24, count: 1)[0], slice(loadPNG("box2"), fw: 28, fh: 24, count: 1)[0]]
        saw = slice(loadPNG("saw"), fw: 38, fh: 38, count: 8)
        let b = loadPNG("birds")
        birds = [slice(b, fw: 32, fh: 32, row: 0, count: 5), slice(b, fw: 32, fh: 32, row: 1, count: 5)]
        birdPadLeft = birds.map { $0.map(\.mask.padLeft).min()! }
        birdPadBottom = birds.map { $0.map(\.mask.padBottom).min()! }
        fruits = ["cherries", "apple", "strawberry", "orange"].map { slice(loadPNG("fruit_" + $0), fw: 32, fh: 32, count: 17) }
        poof = slice(loadPNG("poof"), fw: 32, fh: 32, count: 6).map(\.image)
        let white = loadPNG("font_white"), black = loadPNG("font_black")
        let rows = ["ABCDEFGHIJ", "KLMNOPQRST", "UVWXYZ", "0123456789", ".,:?!()+-"]
        for (r, chars) in rows.enumerated() {
            for (i, c) in chars.enumerated() {
                let rect = CGRect(x: i * 8, y: r * 10, width: 8, height: 10)
                glyphs[c] = (white.cropping(to: rect)!, black.cropping(to: rect)!)
            }
        }
        setCharacter(character)
    }

    func setCharacter(_ id: String) {
        let valid = characters.contains { $0.id == id } ? id : "vita"
        dino = slice(loadPNG("dino_" + valid), fw: 24, fh: 24, count: 24)
        dinoHit = dino.map { $0.mask.eroded() }
    }
}

// MARK: - Game model

enum Phase { case idle, running, dead }
enum Sfx { case jump, point, hit, fruit }

enum Kind {
    case spikes(Int), box(Int), saw, bird(Int, high: Bool), fruit(Int)
}

struct Thing {
    var kind: Kind
    var x: Double          // left edge of the visible body
    var y: Double = 0      // body bottom (fruit only)
    var t: Double = 0
    var gone = false
    var width: Double {
        switch kind {
        case .spikes(let n): return Double(n * 15)
        case .box: return 20
        case .saw: return 38
        case .bird: return 27
        case .fruit: return 14
        }
    }
    var isFruit: Bool { if case .fruit = kind { return true }; return false }
    var isHighBird: Bool { if case .bird(_, let high) = kind { return high }; return false }
    var extraSpeed: Double { if case .bird = kind { return 22 }; return 0 }
}

struct Part { let frame: Frame; let x: Double; let y: Double }   // frame origin in world px

struct Effect {
    enum Look { case dust, poof, text(String) }
    var look: Look
    var x: Double, y: Double
    var t = 0.0
    var life: Double
}

final class Game {
    let art: Art
    var phase = Phase.idle
    var paused = false
    var worldW = 360.0
    var dinoY = 0.0, vy = 0.0, onGround = true, holding = false
    var speed = K.startSpeed, score = 0.0, best = 0
    var things: [Thing] = []
    var fx: [Effect] = []
    var gapLeft = 0.0
    var clock = 0.0, runPhase = 0.0, deadAt = -100.0, bufferedJump = -100.0, flashAt = -100.0
    var scroll = 0.0
    var rng: RNG
    var autopilot = false
    private var aiRun = false        // autopilot touched this run: don't record a best score
    private var aiHolding = false
    var sound: (Sfx) -> Void = { _ in }
    var onBest: (Int) -> Void = { _ in }
    var onDeath: () -> Void = {}

    init(art: Art, seed: UInt64 = UInt64.random(in: 1...UInt64.max)) {
        self.art = art
        rng = RNG(s: seed)
    }

    // Input

    func press() {
        if paused { paused = false; return }
        switch phase {
        case .idle:
            start(); holding = true; jump()
        case .running:
            holding = true
            if onGround { jump() } else { bufferedJump = clock }
        case .dead:
            if clock - deadAt > 0.45 { start(); holding = true; jump() }
        }
    }

    func release() {
        holding = false
        if phase == .running && !onGround && vy > K.releaseV { vy = K.releaseV }
    }

    func pause() { if phase == .running { paused = true; holding = false } }

    private func start() {
        phase = .running; paused = false
        things = []; fx = []
        speed = K.startSpeed; score = 0; runPhase = 0
        gapLeft = max(120, worldW * 0.55)
        dinoY = 0; vy = 0; onGround = true
        aiRun = autopilot
    }

    private func jump() {
        vy = K.jumpV; onGround = false
        sound(.jump)
    }

    // Simulation

    func step(_ dt: Double) {
        clock += dt
        if autopilot { think() }
        if paused { return }

        if !onGround {
            vy -= K.gravity * dt
            dinoY += vy * dt
            if dinoY <= 0 {
                dinoY = 0; vy = 0; onGround = true
                if phase == .running { landed() }
            }
        }
        for i in fx.indices {
            fx[i].t += dt
            if case .dust = fx[i].look, phase == .running { fx[i].x -= speed * 0.5 * dt }
        }
        fx.removeAll { $0.t >= $0.life }

        switch phase {
        case .idle: return
        case .dead:
            if !autopilot && clock - deadAt > 25 { phase = .idle; things = []; fx = [] }
            return
        case .running: break
        }

        speed = min(K.maxSpeed, speed + K.accel * dt)
        let hundreds = Int(score) / 100
        score += speed * dt / K.pxPerPoint
        if Int(score) / 100 > hundreds { flashAt = clock; sound(.point) }
        scroll += speed * dt
        runPhase += dt * min(20, 8 + speed / 20)

        for i in things.indices {
            things[i].x -= (speed + things[i].extraSpeed) * dt
            things[i].t += dt
        }
        things.removeAll { $0.x + $0.width < -60 }
        gapLeft -= speed * dt
        if gapLeft <= 0 { spawn() }
        collide()
    }

    private func landed() {
        fx.append(Effect(look: .dust, x: K.dinoX - 2, y: -4, life: 0.3))
        fx.append(Effect(look: .dust, x: K.dinoX + 8, y: -4, life: 0.25))
        if clock - bufferedJump < 0.15 {
            bufferedJump = -100
            jump()
            if !holding { vy = 150 }
        }
    }

    private func spawn() {
        var options: [(Kind, Double)] = [(.spikes(1), 3), (.spikes(2), 2)]
        if score >= 100 { options.append((.box(rng.int(2)), 2)) }
        if score >= 200 { options.append((.saw, 1.5)) }
        if score >= 250 { options.append((.spikes(3), 1.3)) }
        if score >= 350 {
            options.append((.bird(rng.int(2), high: true), 1.3))
            options.append((.bird(rng.int(2), high: false), 1.3))
        }
        var r = rng.unit() * options.reduce(0) { $0 + $1.1 }
        var kind = options[0].0
        for (k, w) in options { if r < w { kind = k; break }; r -= w }

        let thing = Thing(kind: kind, x: worldW + 4)
        things.append(thing)
        let gap = speed * rng.range(0.75, 1.6) + 26
        gapLeft = thing.width + gap
        if !thing.isHighBird, rng.unit() < 0.2 {
            var f = Thing(kind: .fruit(rng.int(4)), x: worldW + 4 + thing.width + gap * rng.range(0.4, 0.6))
            f.y = rng.range(9, 22)
            things.append(f)
        }
    }

    var dinoFrame: Int {
        switch phase {
        case .idle: return Int(clock * 5) % 4
        case .dead:
            let seq = [13, 14, 15, 16, 14]
            return seq[min(Int((clock - deadAt) * 12), seq.count - 1)]
        case .running:
            if !onGround { return vy > 0 ? 6 : 9 }
            return 4 + Int(runPhase) % 6
        }
    }

    func parts(_ t: Thing) -> [Part] {
        switch t.kind {
        case .spikes(let n):
            let f = art.spike
            return (0..<n).map { Part(frame: f, x: t.x + Double($0 * 15 - f.mask.padLeft), y: Double(-f.mask.padBottom)) }
        case .box(let v):
            let f = art.boxes[v]
            return [Part(frame: f, x: t.x - Double(f.mask.padLeft), y: Double(-f.mask.padBottom))]
        case .saw:
            return [Part(frame: art.saw[Int(t.t * 18) % 8], x: t.x, y: -22)]   // half buried, 16 px showing
        case .bird(let c, let high):
            let x = t.x - Double(art.birdPadLeft[c])
            if high {
                return [Part(frame: art.birds[c][Int(t.t * 9) % 5], x: x, y: K.highBirdBottom - Double(art.birdPadBottom[c]))]
            }
            let f = art.birds[c][2]   // wings level: a low glide
            return [Part(frame: f, x: x, y: K.lowBirdBottom - Double(f.mask.padBottom))]
        case .fruit(let k):
            let f = art.fruits[k][Int(t.t * 20) % 17]
            let f0 = art.fruits[k][0].mask
            return [Part(frame: f, x: t.x - Double(f0.padLeft), y: t.y - Double(f0.padBottom))]
        }
    }

    private func collide() {
        let i = dinoFrame
        let dx = Int(K.dinoX.rounded()), dy = Int((dinoY - 3).rounded())
        for n in things.indices where !things[n].gone {
            let fruit = things[n].isFruit
            let me = fruit ? art.dino[i].mask : art.dinoHit[i]
            for p in parts(things[n]) where overlaps(me, dx, dy, p.frame.mask, Int(p.x.rounded()), Int(p.y.rounded())) {
                if fruit { collect(n); break }
                die(); return
            }
        }
    }

    private func collect(_ n: Int) {
        things[n].gone = true
        score += K.fruitBonus
        let p = parts(things[n])[0]
        fx.append(Effect(look: .poof, x: p.x, y: p.y, life: 0.33))
        fx.append(Effect(look: .text("+50"), x: things[n].x - 3, y: things[n].y + 16, life: 0.7))
        sound(.fruit)
    }

    private func die() {
        phase = .dead; deadAt = clock; holding = false; aiHolding = false
        sound(.hit)
        if !aiRun && Int(score) > best { best = Int(score); onBest(best) }
        onDeath()
    }

    /// Autopilot: plays the game itself (demo mode, and the self-test's fairness check).
    private func think() {
        switch phase {
        case .idle: press(); release(); return
        case .dead: if clock - deadAt > 1.6 { press(); release() }; return
        case .running: break
        }
        if paused { return }
        if aiHolding && !onGround && vy < 30 { aiHolding = false; release() }
        guard onGround else { return }
        let body = K.dinoX + 4
        guard let next = things.filter({ !$0.isFruit && !$0.isHighBird && $0.x + $0.width > body })
            .min(by: { $0.x < $1.x }) else { return }
        let rel = speed + next.extraSpeed
        let travel = rel * 2 * K.jumpV / K.gravity
        let lead = max(2, (travel - next.width - 15) / 2)
        if next.x - (body + 15) <= lead { press(); aiHolding = true }
    }
}

// MARK: - Rendering (Core Animation: the GPU composites sprite layers; the CPU only moves them)

final class Scene {
    let art: Art
    let root = CALayer()
    private let backdrop = CALayer()           // shows the click-to-jump zone while hovered
    private let world = CALayer()
    private let groundL = CALayer()            // static line, edge fade baked in
    private let thingBox = CALayer()           // clips at the ground so the saw sits half buried
    private let shadowL = CALayer(), dinoL = CALayer(), hudL = CALayer(), msgL = CALayer()
    private var thingPool: [CALayer] = [], fxPool: [CALayer] = [], pebblePool: [CALayer] = []
    private var hudKey = "", msgKey = ""
    private var pebblesColored = 0
    private var textCache: [String: CGImage] = [:]
    private(set) var px: CGFloat = 0, backing: CGFloat = 0, size = CGSize.zero
    static let pebblePeriod = 700.0

    private let pebbles: [(x: Double, y: Double, w: Double)] = {
        var r = RNG(s: 7)
        return (0..<70).map { _ in (r.range(0, 698), r.unit() < 0.5 ? -2 : -3, r.unit() < 0.7 ? 1 : 2) }
    }()

    init(art: Art) {
        self.art = art
        backdrop.cornerRadius = 10
        backdrop.backgroundColor = CGColor(gray: 0, alpha: 0.08)
        backdrop.borderColor = CGColor(gray: 1, alpha: 0.22)
        backdrop.borderWidth = 1
        backdrop.isHidden = true
        thingBox.masksToBounds = true
        root.addSublayer(backdrop)
        root.addSublayer(world)
        world.addSublayer(groundL)
        world.addSublayer(shadowL)
        world.addSublayer(thingBox)
        world.addSublayer(dinoL)
        root.addSublayer(hudL)
        root.addSublayer(msgL)
        [groundL, shadowL, dinoL, hudL, msgL].forEach(pixelate)
    }

    private func pixelate(_ l: CALayer) {
        l.magnificationFilter = .nearest
        l.minificationFilter = .nearest
        l.contentsGravity = .resize
    }
    private func snap(_ v: CGFloat) -> CGFloat { (v * backing).rounded() / backing }
    var tp: CGFloat { max(1, (px * backing / 2).rounded()) / backing }     // points per font pixel

    func layout(size: CGSize, px: CGFloat, backing: CGFloat) {
        guard size != self.size || px != self.px || backing != self.backing, size.width > 0 else { return }
        self.size = size; self.px = px; self.backing = backing
        CATransaction.begin(); CATransaction.setDisableActions(true)
        root.frame = CGRect(origin: .zero, size: size)
        backdrop.frame = root.bounds.insetBy(dx: 0.5, dy: 0.5)
        world.frame = root.bounds
        let groundTop = snap(CGFloat(K.below) * px)
        thingBox.frame = CGRect(x: 0, y: groundTop, width: size.width, height: size.height - groundTop)
        groundL.contents = groundImage()
        groundL.frame = CGRect(x: 0, y: groundTop - px, width: size.width, height: px)
        hudKey = ""; msgKey = ""; textCache = [:]
        CATransaction.commit()
    }

    /// Edge fade (0...1) at a point x: the world fades in on the right and out on the left.
    /// Per-layer opacity instead of a mask layer: masks cost WindowServer an offscreen pass every frame.
    func fade(_ x: CGFloat) -> Float {
        Float(max(0, min(1, x / (10 * px), (size.width - x) / (28 * px))))
    }

    /// The ground line: a light top edge over a mid-grey band reads on light and dark desktops.
    private func groundImage() -> CGImage {
        let b = backing, w = size.width, h = px
        let W = Int((w * b).rounded()), H = max(1, Int((h * b).rounded()))
        let ctx = CGContext(data: nil, width: W, height: H, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for x in 0..<W {
            let f = CGFloat(fade(CGFloat(x) / b))
            ctx.setFillColor(CGColor(gray: 0.38, alpha: 0.6 * f))
            ctx.fill(CGRect(x: x, y: 0, width: 1, height: H - 1))
            ctx.setFillColor(CGColor(gray: 1, alpha: 0.5 * f))
            ctx.fill(CGRect(x: x, y: H - 1, width: 1, height: 1))
        }
        return ctx.makeImage()!
    }

    /// World px -> layer frame (points), relative to `parentY` (0 for world, ground top for things).
    private func place(_ l: CALayer, _ img: CGImage, _ x: Double, _ y: Double, parentY: CGFloat = 0) {
        if (l.contents as AnyObject?) !== img { l.contents = img }
        l.frame = CGRect(x: snap(CGFloat(x) * px), y: snap(CGFloat(y + K.below) * px) - parentY,
                         width: CGFloat(img.width) * px, height: CGFloat(img.height) * px)
    }

    private func pooled(_ pool: inout [CALayer], _ i: Int, in parent: CALayer) -> CALayer {
        if i == pool.count {
            let l = CALayer()
            pixelate(l)
            parent.addSublayer(l)
            pool.append(l)
        }
        pool[i].isHidden = false
        return pool[i]
    }

    func update(_ g: Game, hover: Bool, hint: String) {
        guard size.width > 0 else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        backdrop.isHidden = !hover

        // Pebbles under the ground line scroll with the world (tiny colour layers, no bitmaps).
        var n = 0
        let period = Scene.pebblePeriod
        let shift = g.scroll.truncatingRemainder(dividingBy: period)
        for k in 0...Int(g.worldW / period) + 1 {
            for p in pebbles {
                var x = p.x - shift
                if x < 0 { x += period }
                x += Double(k) * period
                if x > g.worldW + 2 { continue }
                let l = pooled(&pebblePool, n, in: world)
                if n >= pebblesColored { l.backgroundColor = CGColor(gray: 0.45, alpha: 1); pebblesColored = n + 1 }
                l.frame = CGRect(x: snap(CGFloat(x) * px), y: CGFloat(p.y + K.below) * px, width: CGFloat(p.w) * px, height: px)
                l.opacity = 0.5 * fade(l.frame.midX)
                n += 1
            }
        }
        for i in n..<pebblePool.count { pebblePool[i].isHidden = true }

        place(shadowL, art.shadow, K.dinoX, -3)
        shadowL.opacity = Float(0.55 * max(0.2, 1 - g.dinoY / 45))
        place(dinoL, art.dino[g.dinoFrame].image, K.dinoX, g.dinoY - 3)

        let groundTop = thingBox.frame.minY
        n = 0
        for t in g.things where !t.gone {
            for p in g.parts(t) {
                let l = pooled(&thingPool, n, in: thingBox)
                place(l, p.frame.image, p.x, p.y, parentY: groundTop)
                l.opacity = fade(l.frame.midX)
                n += 1
            }
        }
        for i in n..<thingPool.count { thingPool[i].isHidden = true }

        n = 0
        for e in g.fx {
            let l = pooled(&fxPool, n, in: world)
            n += 1
            let a = Float(1 - e.t / e.life)
            switch e.look {
            case .dust: place(l, art.dust, e.x, e.y); l.opacity = 0.85 * a * fade(l.frame.midX)
            case .poof: place(l, art.poof[min(5, Int(e.t * 18))], e.x, e.y); l.opacity = fade(l.frame.midX)
            case .text(let s):
                let img = cachedText(s)
                if (l.contents as AnyObject?) !== img { l.contents = img }
                l.frame = textFrame(img, inkX: CGFloat(e.x) * px, inkY: snap(CGFloat(e.y + K.below + e.t * 14) * px))
                l.opacity = a
            }
        }
        for i in n..<fxPool.count { fxPool[i].isHidden = true }

        // HUD: best + score, top right. The score blinks for a second at every 100.
        var hud = g.best > 0 ? "HI " + String(format: "%05d", g.best) : ""
        if g.phase != .idle { hud += (hud.isEmpty ? "" : "  ") + String(format: "%05d", Int(g.score)) }
        if hud != hudKey {
            hudKey = hud
            if hud.isEmpty { hudL.contents = nil } else {
                let img = textImage(hud)
                hudL.contents = img
                hudL.frame = textFrame(img, inkX: size.width - 8 * tp - width(hud), inkY: size.height - 13 * tp)
            }
        }
        hudL.isHidden = g.clock - g.flashAt < 1.0 && Int((g.clock - g.flashAt) * 8) % 2 == 1
        hudL.opacity = 0.95

        var msg = ""
        if g.paused { msg = "PAUSED" } else if g.phase == .dead { msg = "GAME OVER" } else if g.phase == .idle { msg = hint }
        if msg != msgKey {
            msgKey = msg
            if msg.isEmpty { msgL.contents = nil } else {
                let img = textImage(msg)
                msgL.contents = img
                msgL.frame = textFrame(img, inkX: ((size.width - width(msg)) / 2).rounded(), inkY: CGFloat(28 + K.below) * px)
            }
        }
        msgL.opacity = g.phase == .idle && !g.paused ? Float(0.6 + 0.3 * sin(g.clock * 3)) : 1
    }

    // Pixel-font text, baked into small bitmaps only when the string changes.

    func width(_ str: String) -> CGFloat {
        CGFloat(str.reduce(0) { $0 + ($1 == " " ? 4 : 7) } - 1) * tp
    }

    private func cachedText(_ s: String) -> CGImage {
        if let c = textCache[s] { return c }
        let img = textImage(s)
        textCache[s] = img
        return img
    }

    /// Frame for a text bitmap so its ink starts at (inkX, inkY). Bitmaps carry a 2 font-px margin.
    private func textFrame(_ img: CGImage, inkX: CGFloat, inkY: CGFloat) -> CGRect {
        CGRect(x: inkX - 2 * tp, y: inkY - 2 * tp, width: CGFloat(img.width) / backing, height: CGFloat(img.height) / backing)
    }

    /// White pixel font with a 1 px black outline, so it reads over any window.
    private func textImage(_ str: String) -> CGImage {
        let t = tp, b = backing
        let w = width(str) + 4 * t, h = 12 * t
        let ctx = CGContext(data: nil, width: Int((w * b).rounded()), height: Int((h * b).rounded()), bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: b, y: b)
        ctx.interpolationQuality = .none
        for pass in 0..<2 {
            var cx = t             // ink starts 1 px into each 8x10 glyph cell
            for ch in str {
                if ch == " " { cx += 4 * t; continue }
                if let g = art.glyphs[ch] {
                    let r = CGRect(x: cx, y: t, width: 8 * t, height: 10 * t)
                    if pass == 0 {
                        for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                            ctx.draw(g.black, in: r.offsetBy(dx: CGFloat(dx) * t, dy: CGFloat(dy) * t))
                        }
                    } else {
                        ctx.draw(g.white, in: r)
                    }
                }
                cx += 7 * t
            }
        }
        return ctx.makeImage()!
    }
}

// MARK: - Sound (synthesised square-wave blips, no files)

final class Sounds {
    var enabled = true
    private var players: [Sfx: AVAudioPlayer] = [:]
    private let rate = 22050.0

    init() {
        players[.jump] = make(sweep(380, 760, 0.07))
        players[.point] = make(tone(880, 0.06) + tone(1320, 0.11))
        players[.fruit] = make(tone(990, 0.04) + tone(1320, 0.04) + tone(1760, 0.08))
        players[.hit] = make(sweep(320, 70, 0.28, noise: 0.35))
    }

    func play(_ s: Sfx) {
        guard enabled, let p = players[s] else { return }
        p.currentTime = 0
        p.play()
    }

    private func tone(_ f: Double, _ d: Double) -> [Float] { sweep(f, f, d) }

    private func sweep(_ f0: Double, _ f1: Double, _ d: Double, noise: Double = 0) -> [Float] {
        let n = Int(d * rate)
        var out = [Float](repeating: 0, count: n)
        var phase = 0.0
        var r = RNG(s: 99)
        for i in 0..<n {
            let t = Double(i) / Double(n)
            phase += (f0 + (f1 - f0) * t) / rate
            var v = phase.truncatingRemainder(dividingBy: 1) < 0.5 ? 1.0 : -1.0
            if noise > 0 { v = v * (1 - noise) + (r.unit() * 2 - 1) * noise }
            let env = min(1, Double(i) / (0.004 * rate)) * (1 - t)
            out[i] = Float(v * env * 0.22)
        }
        return out
    }

    private func make(_ samples: [Float]) -> AVAudioPlayer? {
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + bytes)
        d.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1)
        u32(UInt32(rate)); u32(UInt32(rate) * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(bytes)
        for s in samples { u16(UInt16(bitPattern: Int16(max(-1, min(1, s)) * 32767))) }
        let p = try? AVAudioPlayer(data: d)
        p?.volume = 0.5
        p?.prepareToPlay()
        return p
    }
}

// MARK: - Settings

enum Prefs {
    static let d = UserDefaults.standard
    static var character: String { get { d.string(forKey: "character") ?? "vita" } set { d.set(newValue, forKey: "character") } }
    static var scale: Double { get { d.object(forKey: "scale") as? Double ?? 2 } set { d.set(newValue, forKey: "scale") } }
    static var width: String { get { d.string(forKey: "width") ?? "720" } set { d.set(newValue, forKey: "width") } }
    static var sound: Bool { get { d.object(forKey: "sound") as? Bool ?? true } set { d.set(newValue, forKey: "sound") } }
    static var autopilot: Bool { get { d.bool(forKey: "autopilot") } set { d.set(newValue, forKey: "autopilot") } }
    static var hidden: Bool { get { d.bool(forKey: "hidden") } set { d.set(newValue, forKey: "hidden") } }
    static var best: Int { get { d.integer(forKey: "best") } set { d.set(newValue, forKey: "best") } }
    static var askedInput: Bool { get { d.bool(forKey: "askedInputMonitoring") } set { d.set(newValue, forKey: "askedInputMonitoring") } }
}

// MARK: - Window

final class StripPanel: NSPanel {
    override var canBecomeKey: Bool { false }    // clicks never steal focus from the app you're working in
    override var canBecomeMain: Bool { false }
}

final class GameView: NSView {
    weak var controller: Controller?
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { controller?.mouse(down: true) }
    override func mouseUp(with event: NSEvent) { controller?.mouse(down: false) }
    override func rightMouseDown(with event: NSEvent) { controller?.popMenu(event, in: self) }
}

// MARK: - Global input (no focus needed)

var controller: Controller!
var eventTap: CFMachPort?
var hotKeyRef: EventHotKeyRef?

/// Right Option = jump, from any app. Listen-only tap: needs Input Monitoring, never blocks the key.
func startRightOptionTap() -> Bool {
    if eventTap != nil { return true }
    let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
    guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                      eventsOfInterest: mask, callback: { _, type, event, _ in
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let t = eventTap { CGEvent.tapEnable(tap: t, enable: true) }
        } else if type == .flagsChanged, event.getIntegerValueField(.keyboardEventKeycode) == Int64(kVK_RightOption) {
            let down = event.flags.rawValue & 0x40 != 0      // NX_DEVICERALTKEYMASK
            DispatchQueue.main.async { controller.key(down: down) }
        }
        return Unmanaged.passUnretained(event)
    }, userInfo: nil) else { return false }
    eventTap = tap
    CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    return true
}

/// ⌃⌥Space = jump. Carbon hot keys need no permission.
func registerHotKey() -> Bool {
    var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                 EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
    InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
        let down = GetEventKind(event) == UInt32(kEventHotKeyPressed)
        DispatchQueue.main.async { controller.key(down: down) }
        return noErr
    }, 2, &specs, nil, nil)
    let id = EventHotKeyID(signature: OSType(0x444B_4F53), id: 1)   // 'DKOS'
    return RegisterEventHotKey(UInt32(kVK_Space), UInt32(controlKey | optionKey), id,
                               GetApplicationEventTarget(), 0, &hotKeyRef) == noErr
}

/// The Dock's icon row, in Cocoa screen coordinates. Needs Accessibility; nil otherwise.
func dockIconFrame() -> CGRect? {
    guard AXIsProcessTrusted(),
          let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else { return nil }
    let app = AXUIElementCreateApplication(dock.processIdentifier)
    var kids: CFTypeRef?
    guard AXUIElementCopyAttributeValue(app, kAXChildrenAttribute as CFString, &kids) == .success,
          let list = kids as? [AXUIElement] else { return nil }
    for el in list {
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &role)
        guard (role as? String) == kAXListRole else { continue }
        var pv: CFTypeRef?, sv: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &pv) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &sv) == .success else { return nil }
        var p = CGPoint.zero, sz = CGSize.zero
        AXValueGetValue(pv as! AXValue, .cgPoint, &p)
        AXValueGetValue(sv as! AXValue, .cgSize, &sz)
        let primaryH = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: p.x, y: primaryH - p.y - sz.height, width: sz.width, height: sz.height)
    }
    return nil
}

// MARK: - App

final class Controller: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let art = Art(character: Prefs.character)
    lazy var game = Game(art: art)
    lazy var scene = Scene(art: art)
    let sounds = Sounds()
    var panel: StripPanel!
    var view: GameView!
    var statusItem: NSStatusItem!
    var link: CADisplayLink?
    var lastTick = 0.0, lastTimestamp = 0.0
    var hover = false, mouseHolding = false
    var tapOn = false, hotKeyOn = false
    var currentRate: Float = 0

    func applicationDidFinishLaunching(_ note: Notification) {
        sounds.enabled = Prefs.sound
        game.best = Prefs.best
        game.autopilot = Prefs.autopilot
        game.sound = { [weak self] s in if self?.game.autopilot == false { self?.sounds.play(s) } }
        game.onBest = { Prefs.best = $0 }

        panel = StripPanel(contentRect: NSRect(x: 0, y: 0, width: 720, height: 112),
                           styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating                  // over windows, under the Dock (magnified icons win)
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]   // not on full-screen spaces
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        view = GameView(frame: panel.contentLayoutRect)
        view.controller = self
        view.layer = scene.root          // layer-hosting: sprites are CALayers composited on the GPU
        view.wantsLayer = true
        panel.contentView = view

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = menuIcon()
        statusItem.button?.toolTip = "Dockosaur"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        statusItem.autosaveName = "DockosaurStatusItem"

        hotKeyOn = registerHotKey()
        setupInputMonitoring(prompt: !Prefs.askedInput && !CommandLine.arguments.contains("--no-prompt"))

        layout()
        if !Prefs.hidden { panel.orderFrontRegardless() }
        startLink()

        // Housekeeping every 2 s: follow Dock changes, pick up a fresh Input Monitoring grant, revive a stalled link.
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.layout()
            if !self.tapOn, CGPreflightListenEventAccess() { self.tapOn = startRightOptionTap() }
            if let t = eventTap, !CGEvent.tapIsEnabled(tap: t) { CGEvent.tapEnable(tap: t, enable: true) }
            if !Prefs.hidden, CACurrentMediaTime() - self.lastTick > 1.5 { self.startLink() }
        }
        NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.layout() }
        let ws = NSWorkspace.shared.notificationCenter
        for n in [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.willSleepNotification] {
            ws.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in self?.game.pause() }
        }
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in self?.game.pause() }
    }

    // Input

    func key(down: Bool) { if Prefs.hidden { return }; down ? press() : game.release() }
    func mouse(down: Bool) { mouseHolding = down; down ? press() : game.release() }
    private func press() {
        if game.holding { return }      // ignore key auto-repeat
        game.press()
        updateRate()
    }

    func setupInputMonitoring(prompt: Bool) {
        if CGPreflightListenEventAccess() { tapOn = startRightOptionTap(); return }
        if prompt {
            Prefs.askedInput = true
            if !CGRequestListenEventAccess() {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
            }
        }
    }

    // Frame loop

    func startLink() {
        link?.invalidate()
        let l = view.displayLink(target: self, selector: #selector(tick(_:)))
        l.add(to: .main, forMode: .common)
        link = l
        lastTimestamp = 0
        currentRate = 0
        lastTick = CACurrentMediaTime()
        updateRate()
    }

    func updateRate() {
        // Full rate only while something moves; the idle dino breathes at 15 fps to save battery.
        let busy = (game.phase == .running && !game.paused) || !game.fx.isEmpty
            || (game.phase == .dead && game.clock - game.deadAt < 1)
        let want: Float = busy ? 60 : 15
        guard want != currentRate, let link else { return }
        currentRate = want
        link.preferredFrameRateRange = want > 30 ? CAFrameRateRange(minimum: 30, maximum: 60, preferred: 60)
                                                 : CAFrameRateRange(minimum: 10, maximum: 20, preferred: 15)
    }

    @objc func tick(_ l: CADisplayLink) {
        lastTick = CACurrentMediaTime()
        var dt = lastTimestamp == 0 ? 1.0 / 60 : l.timestamp - lastTimestamp
        lastTimestamp = l.timestamp
        dt = min(max(dt, 0), 0.1)
        while dt > 0 {          // fixed small sub-steps keep collisions honest at low frame rates
            let h = min(dt, 1.0 / 120)
            game.step(h)
            dt -= h
        }
        let inside = panel.isVisible && panel.frame.contains(NSEvent.mouseLocation)
        if inside != hover {
            hover = inside
            panel.ignoresMouseEvents = !inside
            if !inside && mouseHolding { mouse(down: false) }
        }
        updateRate()
        render()
    }

    func render() {
        scene.layout(size: view.bounds.size, px: CGFloat(Prefs.scale), backing: panel.backingScaleFactor)
        scene.update(game, hover: hover,
                     hint: tapOn ? "TAP RIGHT OPTION TO PLAY" : hotKeyOn ? "CLICK OR CTRL+OPT+SPACE" : "CLICK TO PLAY")
    }

    // Placement: centred above the Dock, ground on the Dock's top edge.

    func layout() {
        guard let panel else { return }
        let screens = NSScreen.screens
        guard let screen = screens.first(where: { $0.visibleFrame.minY > $0.frame.minY + 1 }) ?? screens.first else { return }
        let s = CGFloat(Prefs.scale)
        let vf = screen.visibleFrame, f = screen.frame
        let height = CGFloat(K.below + K.above) * s
        var width: CGFloat = 720, midX = vf.midX
        switch Prefs.width {
        case "dock":
            if let d = dockIconFrame(), screen.frame.intersects(d) { width = d.width; midX = d.midX }
        case "full": width = vf.width
        default: width = CGFloat(Double(Prefs.width) ?? 720)
        }
        width = min(max(width, 480), vf.width)
        width = (width / s).rounded(.down) * s
        let groundY = vf.minY > f.minY + 1 ? vf.minY : f.minY + 2
        var x = (midX - width / 2).rounded()
        x = min(max(x, vf.minX), vf.maxX - width)
        let frame = NSRect(x: x, y: (groundY - CGFloat(K.below) * s).rounded(), width: width, height: height)
        if panel.frame != frame { panel.setFrame(frame, display: true) }
        game.worldW = Double(width / s)
    }

    // Menu bar

    func menuIcon() -> NSImage {
        let f = art.dino[0].image.cropping(to: CGRect(x: 3, y: 3, width: 18, height: 19))!
        let img = NSImage(size: NSSize(width: 18, height: 19), flipped: false) { r in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            ctx.interpolationQuality = .none
            ctx.draw(f, in: r)
            return true
        }
        return img
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let head = NSMenuItem(title: game.best > 0 ? "Dockosaur · best \(game.best)" : "Dockosaur", action: nil, keyEquivalent: "")
        head.isEnabled = false
        menu.addItem(head)
        menu.addItem(.separator())

        if game.phase == .running {
            menu.addItem(item(game.paused ? "Resume" : "Pause", #selector(togglePause)))
        } else {
            menu.addItem(item("New Game", #selector(newGame)))
        }
        menu.addItem(.separator())

        let controls = NSMenuItem(title: "Jump", action: nil, keyEquivalent: "")
        controls.isEnabled = false
        menu.addItem(controls)
        if tapOn {
            menu.addItem(info("    Right ⌥ (tap, hold for higher)"))
        } else {
            menu.addItem(item("    Enable Right ⌥ to Jump…", #selector(enableRightOption)))
        }
        if hotKeyOn { menu.addItem(info("    ⌃⌥Space")) }
        menu.addItem(info("    Click the game strip"))
        menu.addItem(.separator())

        menu.addItem(submenu("Dino", characters.map { ($0.name, $0.id) }, current: Prefs.character, #selector(pickCharacter(_:))))
        menu.addItem(submenu("Size", [("Small", "1.5"), ("Medium", "2.0"), ("Large", "3.0")],
                             current: String(format: "%.1f", Prefs.scale), #selector(pickScale(_:))))
        var widths: [(String, String)] = [("Narrow", "480"), ("Medium", "720"), ("Wide", "960"), ("Full Width", "full")]
        widths.insert((AXIsProcessTrusted() ? "Match Dock" : "Match Dock (needs Accessibility)…", "dock"), at: 0)
        menu.addItem(submenu("Width", widths, current: Prefs.width, #selector(pickWidth(_:))))
        menu.addItem(toggle("Sound", Prefs.sound, #selector(toggleSound)))
        menu.addItem(toggle("Autopilot (plays itself)", Prefs.autopilot, #selector(toggleAutopilot)))
        menu.addItem(.separator())
        menu.addItem(toggle("Show Game", !Prefs.hidden, #selector(toggleHidden)))
        menu.addItem(toggle("Launch at Login", SMAppService.mainApp.status == .enabled, #selector(toggleLogin)))
        menu.addItem(item("Reset Best Score", #selector(resetBest)))
        menu.addItem(item("About Dockosaur…", #selector(about)))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Dockosaur", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    func popMenu(_ event: NSEvent, in view: NSView) {
        guard let menu = statusItem.menu else { return }
        menuNeedsUpdate(menu)
        NSMenu.popUpContextMenu(menu, with: event, for: view)
    }

    private func item(_ title: String, _ sel: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: sel, keyEquivalent: "")
        i.target = self
        return i
    }
    private func info(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }
    private func toggle(_ title: String, _ on: Bool, _ sel: Selector) -> NSMenuItem {
        let i = item(title, sel)
        i.state = on ? .on : .off
        return i
    }
    private func submenu(_ title: String, _ options: [(String, String)], current: String, _ sel: Selector) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for (name, value) in options {
            let i = item(name, sel)
            i.representedObject = value
            i.state = value == current ? .on : .off
            sub.addItem(i)
        }
        parent.submenu = sub
        return parent
    }

    @objc func togglePause() { if game.paused { game.paused = false } else { game.pause() }; updateRate() }
    @objc func newGame() { if game.phase == .dead { game.deadAt = -100 }; game.press(); game.release(); updateRate() }
    @objc func enableRightOption() {
        setupInputMonitoring(prompt: true)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!)
    }
    @objc func pickCharacter(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        Prefs.character = id
        art.setCharacter(id)
        statusItem.button?.image = menuIcon()
        render()
    }
    @objc func pickScale(_ sender: NSMenuItem) {
        guard let v = (sender.representedObject as? String).flatMap(Double.init) else { return }
        Prefs.scale = v
        layout()
    }
    @objc func pickWidth(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? String else { return }
        Prefs.width = v
        if v == "dock" && !AXIsProcessTrusted() {
            _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary)
        }
        layout()
    }
    @objc func toggleSound() { Prefs.sound.toggle(); sounds.enabled = Prefs.sound }
    @objc func toggleAutopilot() { Prefs.autopilot.toggle(); game.autopilot = Prefs.autopilot; updateRate() }
    @objc func toggleHidden() {
        Prefs.hidden.toggle()
        if Prefs.hidden { game.pause(); panel.orderOut(nil); link?.isPaused = true }
        else { layout(); panel.orderFrontRegardless(); link?.isPaused = false; startLink() }
    }
    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            NSLog("Dockosaur: launch at login failed: \(error)")
        }
    }
    @objc func resetBest() { game.best = 0; Prefs.best = 0 }
    @objc func about() {
        let a = NSAlert()
        a.messageText = "Dockosaur"
        a.informativeText = """
        An endless runner that lives on top of your Dock.
        Jump with Right ⌥, ⌃⌥Space, or a click. Hold for a higher jump.
        Stay low under high-flying hawks.

        Dino sprites: Arks (@ArksDigital), CC BY 4.0, arks.itch.io/dino-characters
        Spikes, crates, saw, fruit, dust & font: Pixel Frog, CC0, pixelfrog-assets.itch.io
        Hawks: MoikMellah, CC0, opengameart.org/content/animated-birds-32x32
        """
        NSApp.activate(ignoringOtherApps: true)
        a.runModal()
    }
}

// MARK: - Offline tools: --snapshot and --selftest

func snapshot(_ args: [String]) {
    func arg(_ k: String) -> String? { args.firstIndex(of: k).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
    let out = arg("--snapshot")!
    let seconds = Double(arg("--seconds") ?? "8") ?? 8
    let scale = CGFloat(Double(arg("--scale") ?? "2") ?? 2)
    let widthPt = CGFloat(Double(arg("--width") ?? "720") ?? 720)
    let art = Art(character: arg("--dino") ?? "vita")
    let g = Game(art: art, seed: UInt64(arg("--seed") ?? "3") ?? 3)
    g.best = Int(arg("--best") ?? "0") ?? 0
    g.worldW = Double(widthPt / scale)
    if arg("--phase") != "idle" {
        g.autopilot = true
        if let s = arg("--score").flatMap(Double.init) { g.press(); g.release(); g.score = s }
        var t = 0.0
        while t < seconds { g.step(1.0 / 120); t += 1.0 / 120 }
        if arg("--phase") == "dead" { g.autopilot = false; g.things.removeAll(); g.paused = false
            // run into a wall of spikes to show the game-over screen
            g.things.append(Thing(kind: .spikes(3), x: K.dinoX + 6)); g.step(1.0 / 120); g.step(0.5) }
    } else {
        g.step(seconds)
    }
    let b: CGFloat = 2
    let size = CGSize(width: widthPt, height: CGFloat(K.below + K.above) * scale + (args.contains("--dock") ? 40 : 0))
    let ctx = CGContext(data: nil, width: Int(size.width * b), height: Int(size.height * b), bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: b, y: b)
    switch arg("--bg") ?? "dark" {
    case "light": ctx.setFillColor(CGColor(red: 0.93, green: 0.93, blue: 0.95, alpha: 1)); ctx.fill(CGRect(origin: .zero, size: size))
    case "none": break
    default: ctx.setFillColor(CGColor(red: 0.12, green: 0.13, blue: 0.16, alpha: 1)); ctx.fill(CGRect(origin: .zero, size: size))
    }
    if args.contains("--dock") {   // fake Dock band under the strip for a context shot
        ctx.setFillColor(CGColor(gray: 1, alpha: 0.16))
        ctx.addPath(CGPath(roundedRect: CGRect(x: 20, y: 4, width: size.width - 40, height: 32), cornerWidth: 12, cornerHeight: 12, transform: nil))
        ctx.fillPath()
        ctx.translateBy(x: 0, y: 40 - CGFloat(K.below) * scale)
    }
    // Same layer tree as the live app, rendered in software.
    let scene = Scene(art: art)
    scene.layout(size: CGSize(width: widthPt, height: CGFloat(K.below + K.above) * scale), px: scale, backing: b)
    scene.update(g, hover: args.contains("--hover"), hint: "TAP RIGHT OPTION TO PLAY")
    ctx.interpolationQuality = .none
    scene.root.render(in: ctx)
    let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, ctx.makeImage()!, nil)
    CGImageDestinationFinalize(dest)
    print("wrote \(out)  phase=\(g.phase) score=\(Int(g.score)) things=\(g.things.count)")
}

func selftest() -> Int32 {
    var fails = 0
    func check(_ ok: Bool, _ what: String) { if !ok { fails += 1; print("FAIL: \(what)") } }
    let art = Art(character: "vita")
    for c in characters { art.setCharacter(c.id); check(art.dino.count == 24 && !art.dino[4].mask.isEmpty, "dino \(c.id) frames") }
    art.setCharacter("vita")
    check(art.dino[4...9].map(\.mask.padBottom).min() == 3 && art.dino[4].mask.padLeft == 4, "dino feet/left padding is 3/4 px")
    check(art.saw.count == 8 && art.birds.allSatisfy { $0.count == 5 && !$0[2].mask.isEmpty }, "saw + bird frames")
    check(art.fruits.allSatisfy { $0.count == 17 }, "fruit frames")
    for ch in "HI 0123456789 GAME OVER PAUSED TAP RIGHT OPTION TO PLAY CLICK OR CTRL+OPT+SPACE +50" where ch != " " {
        check(art.glyphs[ch] != nil, "glyph \(ch)")
    }

    // Physics: a full jump clears the tallest ground hazard (crate, 20 px) and a short hop is lower.
    let g = Game(art: art, seed: 1)
    g.press()
    var apex = 0.0
    for _ in 0..<240 { g.step(1.0 / 120); apex = max(apex, g.dinoY) }
    check(apex > 30 && apex < 36, "full jump apex \(apex)")
    let h = Game(art: art, seed: 1)
    h.press(); h.step(0.05); h.release()
    var hop = 0.0
    for _ in 0..<240 { h.step(1.0 / 120); hop = max(hop, h.dinoY) }
    check(hop < 20 && hop > 10, "short hop apex \(hop)")

    // A standing dino fits under a high hawk; a jumping one doesn't.
    let b = Game(art: art, seed: 1)
    b.press(); b.release(); b.step(1)   // start running, land
    b.things = [Thing(kind: .bird(1, high: true), x: K.dinoX + 4)]
    for _ in 0..<12 { b.things[0].x = K.dinoX + 4; b.step(1.0 / 120) }
    check(b.phase == .running, "dino passes under a high hawk")

    // Fairness: the autopilot should survive long stretches at every speed.
    var deaths = 0, bestScore = 0
    for seed in 1...6 {
        let a = Game(art: art, seed: UInt64(seed))
        a.autopilot = true
        a.onDeath = { deaths += 1; bestScore = max(bestScore, Int(a.score)) }
        for _ in 0..<(300 * 120) { a.step(1.0 / 120) }
        bestScore = max(bestScore, Int(a.score))
    }
    print("autopilot: \(deaths) deaths in 30 simulated minutes, best run \(bestScore)")
    check(deaths <= 6, "autopilot dies too often (\(deaths)) - gaps may be unfair")
    print(fails == 0 ? "selftest OK" : "selftest: \(fails) failures")
    return fails == 0 ? 0 : 1
}

// MARK: - Entry

let args = CommandLine.arguments
if args.contains("--selftest") { exit(selftest()) }
if args.contains("--snapshot") { snapshot(args); exit(0) }

let app = NSApplication.shared
controller = Controller()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
