import AppKit
import ImageIO
import Carbon

// 谷谷 & 团团 desktop pets. Two borderless panels, one per cat.
// Artwork is AI-generated keyframes; the only code-driven motion is a hop for reminders
// so the cats stay smooth even where the generated frames are sparse.

// MARK: - Data

struct FrameMeta: Decodable { let file: String; let width: Int; let height: Int; let footX: Double }

struct ActionSpec: Decodable {
    let label: String
    let dir: String
    let seq: [[Double]]          // [frameIndex, milliseconds]
    let loop: Bool?
    let scale: Double?           // corrects sheets drawn at a different pixel size than idle
}

struct CatSpec: Decodable {
    let id: String
    let name: String
    let height: Double           // on-screen height (pt) of idle frame 0 at 100% size
    let actions: [String: ActionSpec]
    let order: [String]          // menu order
    let click: [String]          // actions a click picks from
}

struct PairSpec: Decodable {
    let id: String
    let label: String
    let height: Double           // on-screen height (pt) of frame 0 at 100% size
    let action: ActionSpec
    let seconds: Double?         // how long it lasts before they split up (nil = until clicked)
    let group: String?           // variants sharing a group are picked at random
}

struct Manifest: Decodable { let cats: [CatSpec]; let pairs: [PairSpec]? }

struct Sprite {
    let image: CGImage
    let footX: Double            // 0...1 of the image width
}

final class ActionFrames {
    let spec: ActionSpec
    let sprites: [Sprite]
    init(spec: ActionSpec, root: URL) throws {
        self.spec = spec
        let dir = root.appendingPathComponent(spec.dir)
        let meta = try JSONDecoder().decode([FrameMeta].self, from: Data(contentsOf: dir.appendingPathComponent("f.json")))
        sprites = try meta.map { m in
            guard let src = CGImageSourceCreateWithURL(dir.appendingPathComponent(m.file) as CFURL, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                throw NSError(domain: "CatPets", code: 1, userInfo: [NSLocalizedDescriptionKey: "缺少图片：\(spec.dir)/\(m.file)"])
            }
            return Sprite(image: img, footX: m.footX / Double(m.width))
        }
    }
    var duration: Double { spec.seq.reduce(0) { $0 + $1[1] } / 1000 }
    func frame(at t: Double) -> Int {
        var ms = (spec.loop == true ? t.truncatingRemainder(dividingBy: duration) : min(t, duration)) * 1000
        for step in spec.seq {
            if ms < step[1] { return Int(step[0]) }
            ms -= step[1]
        }
        return Int(spec.seq.last![0])
    }
}

// MARK: - Motion helpers (all times in seconds)

func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double { min(max(v, lo), hi) }

/// Squash-and-stretch hop. Returns (lift in pt, scaleX, scaleY).
func hopCurve(_ t: Double, height: Double) -> (Double, Double, Double) {
    let d = 0.5
    guard t >= 0, t < d else { return (0, 1, 1) }
    let p = t / d
    if p < 0.18 { let q = p / 0.18; return (0, 1 + 0.08 * q, 1 - 0.1 * q) }
    if p < 0.78 { let q = (p - 0.18) / 0.6; return (height * sin(.pi * q), 0.96, 1.05) }
    let q = (p - 0.78) / 0.22
    return (0, 1 + 0.07 * sin(.pi * q), 1 - 0.08 * sin(.pi * q))
}

// MARK: - One cat

final class CatPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class CatView: NSView {
    weak var cat: Cat?
    private var startMouse = NSPoint.zero
    private var startOrigin = NSPoint.zero
    private var dragged = false
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(bounds)
        cat?.draw(in: ctx, bounds: bounds)
    }
    override func mouseDown(with event: NSEvent) {
        guard let w = window else { return }
        startMouse = w.convertPoint(toScreen: event.locationInWindow)
        startOrigin = w.frame.origin
        dragged = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard let w = window else { return }
        let p = w.convertPoint(toScreen: event.locationInWindow)
        let dx = p.x - startMouse.x, dy = p.y - startMouse.y
        guard dragged || hypot(dx, dy) > 3 else { return }
        if !dragged { dragged = true; cat?.beginDrag() }
        cat?.drag(to: NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy), pointer: p)
    }
    override func mouseUp(with event: NSEvent) {
        if dragged { cat?.endDrag() } else { cat?.clicked() }
    }
    override func rightMouseDown(with event: NSEvent) {
        guard let menu = cat?.owner?.makeMenu() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

final class Cat {
    let spec: CatSpec
    let actions: [String: ActionFrames]
    weak var owner: AppController?
    let panel: CatPanel
    let view: CatView
    private let settings = UserDefaults.standard
    private let pxPerPt: Double            // sprite pixels per point at 100% size
    private let halfWidthPx: Double        // widest reach left/right of the feet over all frames
    private let tallestPx: Double
    /// While tucked into the Dock gap the cats shrink to fit; nil = the user's size setting.
    var sizeOverride: Double?
    var size: Double { sizeOverride ?? settings.double(forKey: "scale") }

    private(set) var action = "idle"
    private var actionStart = 0.0
    private var hopStart = -10.0
    private var shakeStart = -10.0
    private var dragging = false
    private var lastDragX = 0.0
    private var facingLeft = false
    private var lastActive = 0.0
    private var drawnRect = NSRect.zero
    private var pointerInside = false
    private var walkDir = 1.0, walkEnd = 0.0, nextStroll = 0.0, lastTick = 0.0
    private var walkTarget: Double?            // panel midX to walk to (for meeting the other cat)
    private var dragVX = 0.0, dragVY = 0.0     // smoothed drag speed, pt per event
    private var sidewaysAt = -10.0
    private var falling = false, fallVX = 0.0, fallVY = 0.0   // pt/s, after being let go in mid-air

    init(spec: CatSpec, root: URL, now: Double) throws {
        self.spec = spec
        var a: [String: ActionFrames] = [:]
        for (k, v) in spec.actions { a[k] = try ActionFrames(spec: v, root: root) }
        actions = a
        guard let idle = a["idle"] else { throw NSError(domain: "CatPets", code: 2) }
        pxPerPt = Double(idle.sprites[0].image.height) / spec.height
        let all = a.values.flatMap { act in act.sprites.map { ($0, act.spec.scale ?? 1) } }
        halfWidthPx = all.map { max($0.0.footX, 1 - $0.0.footX) * Double($0.0.image.width) * $0.1 }.max() ?? 1
        tallestPx = all.map { Double($0.0.image.height) * $0.1 }.max() ?? 1
        panel = CatPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        view = CatView(frame: .zero)
        view.cat = self
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = view
        view.toolTip = "\(spec.name) · 单击互动 · 拖动搬家 · 右键菜单"
        view.setAccessibilityElement(true)
        view.setAccessibilityLabel("\(spec.name)，桌面宠物")
        actionStart = now
        lastActive = now
        lastTick = now
        nextStroll = now + Double.random(in: 120...300)
        resize()
    }

    // Big enough for the widest/tallest frame, plus headroom for the reminder hop.
    var panelSize: NSSize {
        let w = max(spec.height * 1.2, 2 * halfWidthPx / pxPerPt * 1.1)
        let h = tallestPx / pxPerPt + spec.height * 0.3
        return NSSize(width: (w * size).rounded(), height: (h * size).rounded())
    }

    func resize() {
        let s = panelSize
        let key = "pos-\(spec.id)"
        var origin = panel.frame.origin
        if panel.frame.width == 0 {
            if let saved = settings.array(forKey: key) as? [Double], saved.count == 2 {
                origin = NSPoint(x: saved[0], y: saved[1])
            } else {
                let vis = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
                let slot = spec.id == "gugu" ? 0.0 : 1.0
                origin = NSPoint(x: vis.maxX - 80 - (slot + 1) * s.width * 1.05, y: vis.minY)
            }
        } else {
            origin.x = panel.frame.midX - s.width / 2
        }
        panel.setFrame(NSRect(origin: origin, size: s), display: true)
        keepOnScreen()
    }

    func savePosition() {
        if owner?.isQuiet == true { return }   // the hideout spot is temporary; keep the real one
        settings.set([panel.frame.minX, panel.frame.minY], forKey: "pos-\(spec.id)")
    }

    /// Size (pt) of the sleeping pose at a given scale, used to fit the cats into a hideout.
    func sleepFootprint(scale: Double) -> NSSize {
        guard let a = actions["sleep"] ?? actions["idle"], let sp = a.sprites.first else { return .zero }
        let k = scale / pxPerPt * (a.spec.scale ?? 1)
        return NSSize(width: Double(sp.image.width) * k, height: Double(sp.image.height) * k)
    }
    /// Put the cat's feet at (midX, bottom) without the usual keep-on-screen clamping.
    func place(midX: Double, bottom: Double) {
        resizeInPlace()
        panel.setFrameOrigin(NSPoint(x: midX - panel.frame.width / 2, y: bottom - 2))
    }
    private func resizeInPlace() {
        let s = panelSize
        panel.setFrame(NSRect(x: panel.frame.midX - s.width / 2, y: panel.frame.minY, width: s.width, height: s.height), display: true)
    }

    func keepOnScreen() {
        let screen = NSScreen.screens.first(where: { $0.visibleFrame.intersects(panel.frame) }) ?? NSScreen.main
        guard let vis = screen?.visibleFrame else { return }
        var o = panel.frame.origin
        o.x = clamp(o.x, vis.minX, vis.maxX - panel.frame.width)
        o.y = clamp(o.y, vis.minY, vis.maxY - panel.frame.height)
        panel.setFrameOrigin(o)
    }

    // MARK: Behaviour

    private var now: Double { owner?.now ?? ProcessInfo.processInfo.systemUptime }

    func play(_ key: String) {
        guard actions[key] != nil else { return }
        lastActive = now
        action = key
        actionStart = now
    }
    func hop() { lastActive = now; hopStart = now }

    /// Walk until the panel's centre reaches `x` (used to meet the other cat).
    func walk(toX x: Double) {
        walkTarget = x
        if abs(x - panel.frame.midX) < 6 { walkTarget = nil; owner?.arrived(self); return }
        walkDir = x < panel.frame.midX ? -1 : 1
        facingLeft = walkDir < 0
        if actions["walk"] != nil { play("walk") } else { action = "idle" }
        hopStart = -10
        walkEnd = .infinity
    }
    var isBusy: Bool { dragging || falling || walkTarget != nil }
    var isIdle: Bool { !dragging && walkTarget == nil && (action == "idle" || action == "sleep") }
    func cancelWalk() { walkTarget = nil; if action == "walk" { play("idle") } }

    /// Walk a few steps, heading toward whichever side of the screen has more room.
    func stroll() {
        guard actions["walk"] != nil, let vis = (panel.screen ?? NSScreen.main)?.visibleFrame else { return }
        walkDir = (panel.frame.midX - vis.minX) > (vis.maxX - panel.frame.midX) ? -1 : 1
        if Double.random(in: 0...1) < 0.3 { walkDir = -walkDir }
        facingLeft = walkDir < 0
        play("walk")
        hopStart = -10
        walkEnd = now + Double.random(in: 2.5...5)
    }

    /// Waking from a nap: stretch first if we have the frames.
    func wake() { play(actions["stretch"] != nil ? "stretch" : "idle") }

    func hovered() {
        if owner?.isQuiet == true { return }
        guard !dragging, now - hopStart > 0.6 else { return }
        if action == "sleep" { wake(); return }
    }
    func clicked() {
        if owner?.isQuiet == true { return }
        if action == "sleep" { wake(); return }
        guard action == "idle" else { return }
        let choices = spec.click.filter { actions[$0] != nil }
        if let pick = choices.randomElement() { play(pick) }
    }
    func beginDrag() {
        if owner?.isQuiet == true { return }
        dragging = true
        falling = false
        lastActive = now
        dragVX = 0; dragVY = 0
        if walkTarget != nil { walkTarget = nil; owner?.meetingCancelled() }
        if actions["held"] != nil { action = "held"; actionStart = now }
        else if action == "sleep" { play("idle") }
    }
    func drag(to origin: NSPoint, pointer: NSPoint) {
        if owner?.isQuiet == true { return }
        let dx = origin.x - panel.frame.minX
        dragVX = dragVX * 0.6 + dx * 0.4
        dragVY = dragVY * 0.6 + (origin.y - panel.frame.minY) * 0.4
        if abs(dx) > 1.5 { facingLeft = dx < 0 }
        let screen = NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) }) ?? NSScreen.main
        var o = origin
        if let vis = screen?.visibleFrame {
            o.x = clamp(o.x, vis.minX, vis.maxX - panel.frame.width)
            o.y = clamp(o.y, vis.minY, vis.maxY - panel.frame.height)
        }
        panel.setFrameOrigin(o)
    }
    func endDrag() {
        if owner?.isQuiet == true { return }
        dragging = false
        // Let go above the floor: drop like a real cat, keeping a little of the throw.
        if settings.bool(forKey: "gravity"), let vis = (panel.screen ?? NSScreen.main)?.visibleFrame, panel.frame.minY > vis.minY + 4 {
            falling = true
            fallVX = clamp(dragVX * 50, -500, 500)
            fallVY = max(0, dragVY * 50)
            if actions["held"] != nil { action = "held"; actionStart = now }
            return
        }
        if action == "held" || action == "walk" { play("idle") }
        savePosition()
        lastActive = now
    }

    func tick(_ now: Double) {
        // Clicks on the transparent margin fall through to whatever is underneath,
        // and hover is detected here rather than with a tracking area for the same reason.
        let mouse = panel.convertPoint(fromScreen: NSEvent.mouseLocation)
        let inside = contains(view.convert(mouse, from: nil))
        if !dragging { panel.ignoresMouseEvents = !inside }
        if inside && !pointerInside { hovered() }
        pointerInside = inside
        if let a = actions[action], a.spec.loop != true, now - actionStart >= a.duration {
            action = "idle"; actionStart = now
        }
        // While carried: moving sideways walks that way; lifting or holding still dangles.
        if dragging {
            dragVX *= 0.85; dragVY *= 0.85
            let sideways = abs(dragVX) > 1.2 && abs(dragVX) > abs(dragVY) * 1.2
            if sideways { facingLeft = dragVX < 0; sidewaysAt = now }
            // A short grace period stops brief pauses in the drag from flickering between poses.
            let walking = now - sidewaysAt < 0.3 && actions["walk"] != nil
            let want = walking ? "walk" : (actions["held"] != nil ? "held" : action)
            if want != action { action = want; actionStart = now }
        }
        let dt = min(0.1, now - lastTick)
        lastTick = now
        if falling && !dragging {
            let vis = (panel.screen ?? NSScreen.main)?.visibleFrame ?? .zero
            var o = panel.frame.origin
            fallVY -= 2600 * dt * size
            fallVX *= pow(0.6, dt)
            o.y += fallVY * dt
            o.x = clamp(o.x + fallVX * dt, vis.minX, vis.maxX - panel.frame.width)
            if o.y <= vis.minY {
                o.y = vis.minY
                if fallVY < -500 * size { fallVY = -fallVY * 0.22; fallVX *= 0.5 }   // one small bounce
                else { falling = false; play("idle"); savePosition() }
            }
            panel.setFrameOrigin(o)
        }
        if let target = walkTarget, !dragging {
            // Heading to meet the other cat: a bit faster, and stop exactly on the spot.
            var o = panel.frame.origin
            let step = walkDir * 60 * size * dt
            if abs(target - panel.frame.midX) <= abs(step) {
                o.x = target - panel.frame.width / 2
                panel.setFrameOrigin(o)
                walkTarget = nil
                play("idle")
                owner?.arrived(self)
            } else {
                o.x += step
                panel.setFrameOrigin(o)
            }
        } else if action == "walk" && !dragging {
            let vis = (panel.screen ?? NSScreen.main)?.visibleFrame ?? .zero
            var o = panel.frame.origin
            o.x += walkDir * 34 * size * dt
            let blocked = o.x < vis.minX || o.x > vis.maxX - panel.frame.width
            if now > walkEnd || blocked { play("idle"); savePosition(); nextStroll = now + Double.random(in: 150...360) }
            else { panel.setFrameOrigin(o) }
        }
        if action == "idle", owner?.strolls == true, actions["walk"] != nil, now > nextStroll, now - lastActive > 20 { stroll() }
        // Fall asleep after a quiet spell (only once sleep frames exist).
        if action == "idle", actions["sleep"] != nil, now - lastActive > 90 {
            if owner?.wantsCuddle(from: self) != true { play("sleep") }
        }
        view.needsDisplay = true
    }

    // MARK: Drawing

    func contains(_ p: NSPoint) -> Bool { drawnRect.insetBy(dx: drawnRect.width * 0.08, dy: 0).contains(p) }

    func draw(in ctx: CGContext, bounds: NSRect) {
        let t = now
        guard let a = actions[action] ?? actions["idle"] else { return }
        let sprite = a.sprites[a.frame(at: t - actionStart)]
        let scale = size / pxPerPt * (a.spec.scale ?? 1)
        let w = Double(sprite.image.width) * scale, h = Double(sprite.image.height) * scale
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        // The cats hold still between frames: no breathing, tilting or swinging.
        // The only code-driven motion left is the hop used to flag a reminder.
        var sx = 1.0, sy = 1.0, lift = 0.0
                if !reduce {
            let (l, hx, hy) = hopCurve(t - hopStart, height: spec.height * size * 0.14)
            lift = l; sx *= hx; sy *= hy
        }

        let footX = bounds.midX, footY = bounds.minY + 2 + lift
        ctx.saveGState()
        ctx.interpolationQuality = .high
        ctx.translateBy(x: footX, y: footY)
        ctx.scaleBy(x: sx * (facingLeft ? -1 : 1), y: sy)
        let rect = CGRect(x: -sprite.footX * w, y: 0, width: w, height: h)
        ctx.draw(sprite.image, in: rect)
        ctx.restoreGState()
        let left = facingLeft ? footX - (w - sprite.footX * w) : footX - sprite.footX * w
        drawnRect = NSRect(x: left, y: bounds.minY, width: w, height: h + lift)
    }
}

// MARK: - Both cats together (one panel showing a two-cat animation)

final class PairView: NSView {
    weak var owner: AppController?
    var draw: ((CGContext, NSRect) -> Void)?
    private var startMouse = NSPoint.zero, startOrigin = NSPoint.zero, dragged = false
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.clear(bounds)
        draw?(ctx, bounds)
    }
    override func mouseDown(with event: NSEvent) {
        guard let w = window else { return }
        startMouse = w.convertPoint(toScreen: event.locationInWindow); startOrigin = w.frame.origin; dragged = false
    }
    override func mouseDragged(with event: NSEvent) {
        guard let w = window else { return }
        let p = w.convertPoint(toScreen: event.locationInWindow)
        let dx = p.x - startMouse.x, dy = p.y - startMouse.y
        guard dragged || hypot(dx, dy) > 3 else { return }
        dragged = true
        w.setFrameOrigin(NSPoint(x: startOrigin.x + dx, y: startOrigin.y + dy))
    }
    override func mouseUp(with event: NSEvent) { if !dragged { owner?.endPair() } }
    override func rightMouseDown(with event: NSEvent) {
        guard let menu = owner?.makeMenu() else { return }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

final class Pair {
    let spec: PairSpec
    let frames: ActionFrames
    let pxPerPt: Double
    init(spec: PairSpec, root: URL) throws {
        self.spec = spec
        frames = try ActionFrames(spec: spec.action, root: root)
        pxPerPt = Double(frames.sprites[0].image.height) / spec.height
    }
    func size(scale: Double) -> NSSize {
        let w = frames.sprites.map { Double($0.image.width) }.max()! / pxPerPt
        let h = frames.sprites.map { Double($0.image.height) }.max()! / pxPerPt
        return NSSize(width: (w * 1.08 * scale).rounded(), height: (h * 1.12 * scale).rounded())
    }
    func draw(in ctx: CGContext, bounds: NSRect, t: Double, scale: Double) {
        let sprite = frames.sprites[frames.frame(at: t)]
        let k = scale / pxPerPt
        let w = Double(sprite.image.width) * k, h = Double(sprite.image.height) * k
        ctx.saveGState()
        ctx.interpolationQuality = .high
        ctx.translateBy(x: bounds.midX, y: bounds.minY + 2)
        ctx.draw(sprite.image, in: CGRect(x: -sprite.footX * w, y: 0, width: w, height: h))
        ctx.restoreGState()
    }
}

// MARK: - Speech bubble

/// A small rounded note that floats above a cat and fades after a few seconds.
final class Bubble {
    private let panel: CatPanel
    private let label = NSTextField(wrappingLabelWithString: "")
    private var hideAt = 0.0
    init() {
        panel = CatPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        let box = NSView()
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor(calibratedWhite: 1, alpha: 0.97).cgColor
        box.layer?.cornerRadius = 12
        box.layer?.borderColor = NSColor(calibratedWhite: 0.2, alpha: 0.9).cgColor
        box.layer?.borderWidth = 1.5
        label.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        label.textColor = NSColor(calibratedWhite: 0.12, alpha: 1)
        label.maximumNumberOfLines = 4
        box.addSubview(label)
        panel.contentView = box
        let click = NSClickGestureRecognizer(target: self, action: #selector(dismiss))
        box.addGestureRecognizer(click)
    }
    func say(_ text: String, above frame: NSRect, seconds: Double = 10) {
        label.stringValue = text
        let maxW: CGFloat = 220
        label.preferredMaxLayoutWidth = maxW
        let size = label.sizeThatFits(NSSize(width: maxW, height: 200))
        let w = min(maxW, size.width) + 24, h = size.height + 18
        label.frame = NSRect(x: 12, y: 9, width: w - 24, height: size.height)
        var origin = NSPoint(x: frame.midX - w / 2, y: frame.maxY - 6)
        if let vis = (NSScreen.screens.first { $0.frame.intersects(frame) } ?? NSScreen.main)?.visibleFrame {
            origin.x = clamp(origin.x, vis.minX + 4, vis.maxX - w - 4)
            origin.y = min(origin.y, vis.maxY - h - 4)
        }
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: w, height: h)), display: true)
        panel.orderFrontRegardless()
        hideAt = ProcessInfo.processInfo.systemUptime + seconds
    }
    func tick() {
        if panel.isVisible, ProcessInfo.processInfo.systemUptime > hideAt { panel.orderOut(nil) }
    }
    @objc func dismiss() { panel.orderOut(nil) }
}

// MARK: - To-dos

struct Todo: Codable {
    var id = UUID()
    var text: String
    var done = false
    var due: Date?
    var notified = false
}

/// Understands "15:00 交报表", "3点半 开会", "10分钟后 关火", "2小时后 …". Returns (text, due).
func parseTodo(_ raw: String, now: Date = Date()) -> (String, Date?) {
    let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    func match(_ pattern: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
        return (0..<m.numberOfRanges).map { i in
            Range(m.range(at: i), in: s).map { String(s[$0]) } ?? ""
        }
    }
    let cal = Calendar.current
    func at(_ h: Int, _ m: Int) -> Date? {
        guard h < 24, m < 60, var d = cal.date(bySettingHour: h, minute: m, second: 0, of: now) else { return nil }
        if d <= now { d = cal.date(byAdding: .day, value: 1, to: d) ?? d }
        return d
    }
    if let g = match(#"^(\d+)\s*分钟后\s*(.*)$"#), let n = Double(g[1]) {
        return (g[2].isEmpty ? s : g[2], now.addingTimeInterval(n * 60))
    }
    if let g = match(#"^(\d+(?:\.\d+)?)\s*(?:个)?小时后\s*(.*)$"#), let n = Double(g[1]) {
        return (g[2].isEmpty ? s : g[2], now.addingTimeInterval(n * 3600))
    }
    if let g = match(#"^(\d{1,2})[:：](\d{2})\s*(.*)$"#), let h = Int(g[1]), let m = Int(g[2]), let d = at(h, m) {
        return (g[3].isEmpty ? s : g[3], d)
    }
    if let g = match(#"^(?:(上午|下午|晚上))?(\d{1,2})点(半|(\d{1,2})分?)?\s*(.*)$"#), var h = Int(g[2]) {
        let m = g[3] == "半" ? 30 : Int(g[4]) ?? 0
        if (g[1] == "下午" || g[1] == "晚上") && h < 12 { h += 12 }
        // "3点" said at 2pm means 3pm, not 3am tomorrow.
        if g[1].isEmpty, h < 12, let today = cal.date(bySettingHour: h, minute: m, second: 0, of: now), today <= now,
           let pm = cal.date(bySettingHour: h + 12, minute: m, second: 0, of: now), pm > now { h += 12 }
        if let d = at(h, m) { return (g[5].isEmpty ? s : g[5], d) }
    }
    return (s, nil)
}

final class TodoStore {
    private(set) var items: [Todo] = []
    var onChange: (() -> Void)?
    private let key = "todos"
    init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let list = try? JSONDecoder().decode([Todo].self, from: data) { items = list }
    }
    private func save() {
        if let data = try? JSONEncoder().encode(items) { UserDefaults.standard.set(data, forKey: key) }
        onChange?()
    }
    @discardableResult func add(_ raw: String) -> Todo? {
        let (text, due) = parseTodo(raw)
        guard !text.isEmpty else { return nil }
        let t = Todo(text: text, due: due)
        items.insert(t, at: 0); save()   // newest first
        return t
    }
    func toggle(_ id: UUID) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].done.toggle(); save()
    }
    func remove(_ id: UUID) { items.removeAll { $0.id == id }; save() }
    func clearDone() { items.removeAll { $0.done }; save() }
    /// Reminders that just came due.
    func takeDue(_ now: Date = Date()) -> [Todo] {
        var fired: [Todo] = []
        for i in items.indices where !items[i].done && !items[i].notified {
            if let d = items[i].due, d <= now { items[i].notified = true; fired.append(items[i]) }
        }
        if !fired.isEmpty { save() }
        return fired
    }
    var openCount: Int { items.filter { !$0.done }.count }
}

func dueLabel(_ d: Date) -> String {
    let f = DateFormatter()
    f.dateFormat = Calendar.current.isDateInToday(d) ? "HH:mm" : "M月d日 HH:mm"
    return f.string(from: d)
}

/// A panel that can take keyboard focus (the cat panels deliberately can't).
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    var onEscape: (() -> Void)?
    override func cancelOperation(_ sender: Any?) { onEscape?() }
}

/// The to-do list window: newest on top, tick to finish, × to delete.
final class TodoWindow: NSObject, NSTextFieldDelegate {
    let panel: KeyPanel
    private let store: TodoStore
    private let doc = FlippedView()
    private let scroll = NSScrollView()
    private let input = NSTextField()
    private let empty = NSTextField(labelWithString: "还没有待办。下面输入一条试试～")
    init(store: TodoStore) {
        self.store = store
        panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 380),
                         styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.title = "待办 · 谷谷和团团"
        panel.level = .floating
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.onEscape = { [weak self] in self?.panel.orderOut(nil) }
        let content = NSView(frame: panel.contentRect(forFrameRect: panel.frame))
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.documentView = doc
        input.placeholderString = "新待办，如：15:00 交报表 / 10分钟后 关火"
        input.delegate = self
        input.target = self
        input.action = #selector(addFromInput)
        let clear = NSButton(title: "清除已完成", target: self, action: #selector(clearDone))
        clear.bezelStyle = .inline
        for v in [scroll, input, clear] { v.translatesAutoresizingMaskIntoConstraints = false; content.addSubview(v) }
        content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            // Fixed comfortable size: without this the window collapses to its narrowest content.
            content.widthAnchor.constraint(equalToConstant: 340),
            content.heightAnchor.constraint(greaterThanOrEqualToConstant: 380),
            scroll.topAnchor.constraint(equalTo: content.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: input.topAnchor, constant: -8),
            input.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            input.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            input.bottomAnchor.constraint(equalTo: clear.topAnchor, constant: -6),
            clear.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            clear.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
        ])
        panel.contentView = content
        panel.setContentSize(NSSize(width: 340, height: 400))
        panel.contentMinSize = NSSize(width: 340, height: 300)
        store.onChange = { [weak self] in self?.reload() }
        reload()
    }
    func show(near frame: NSRect) {
        if !panel.isVisible {
            var o = NSPoint(x: frame.minX - panel.frame.width - 10, y: frame.minY)
            if let vis = NSScreen.main?.visibleFrame {
                o.x = clamp(o.x, vis.minX, vis.maxX - panel.frame.width)
                o.y = clamp(o.y, vis.minY, vis.maxY - panel.frame.height)
            }
            panel.setFrameOrigin(o)
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(input)
    }
    /// Rows are laid out by hand; long items wrap and the row grows to fit, so nothing is cut off.
    func reload() {
        doc.subviews.forEach { $0.removeFromSuperview() }
        let width: CGFloat = 340, pad: CGFloat = 12, boxW: CGFloat = 22
        let textW = width - pad * 2 - 30 - boxW
        var y: CGFloat = 10
        if store.items.isEmpty {
            empty.textColor = .secondaryLabelColor
            empty.frame = NSRect(x: pad, y: y, width: width - pad * 2, height: 22)
            doc.addSubview(empty)
            y += 30
        }
        // Open items first, finished ones below; each group keeps the store's newest-first order.
        let sorted = store.items.filter { !$0.done } + store.items.filter { $0.done }
        for t in sorted {
            var title = t.text
            if let d = t.due { title = "⏰ \(dueLabel(d))  " + title }
            let id = NSUserInterfaceItemIdentifier(t.id.uuidString)
            let box = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggled(_:)))
            box.state = t.done ? .on : .off
            box.identifier = id
            var attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: NSColor.labelColor]
            if t.done { attrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue; attrs[.foregroundColor] = NSColor.secondaryLabelColor }
            let label = NSTextField(wrappingLabelWithString: "")
            label.attributedStringValue = NSAttributedString(string: title, attributes: attrs)
            label.identifier = id
            label.isSelectable = false
            label.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(labelClicked(_:))))
            let textH = ceil(label.cell!.cellSize(forBounds: NSRect(x: 0, y: 0, width: textW, height: .greatestFiniteMagnitude)).height)
            let rowH = max(30, textH + 12)
            box.frame = NSRect(x: pad, y: y + 4, width: boxW, height: 22)
            label.frame = NSRect(x: pad + boxW, y: y + 6, width: textW, height: textH)
            let del = NSButton(title: "×", target: self, action: #selector(removed(_:)))
            del.bezelStyle = .inline
            del.identifier = id
            del.toolTip = "删除"
            del.frame = NSRect(x: width - pad - 24, y: y + 4, width: 24, height: 22)
            let line = NSBox(frame: NSRect(x: pad, y: y + rowH - 1, width: width - pad * 2, height: 1))
            line.boxType = .separator
            [box, label, del, line].forEach { doc.addSubview($0) }
            y += rowH
        }
        doc.frame = NSRect(x: 0, y: 0, width: width, height: max(y + 10, scroll.contentSize.height))
        scroll.contentView.scroll(to: .zero)   // show the newest item
    }
    @objc private func addFromInput() {
        let text = input.stringValue
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        store.add(text)
        input.stringValue = ""
    }
    @objc private func toggled(_ b: NSButton) { if let s = b.identifier?.rawValue, let id = UUID(uuidString: s) { store.toggle(id) } }
    @objc private func labelClicked(_ g: NSClickGestureRecognizer) {
        if let s = g.view?.identifier?.rawValue, let id = UUID(uuidString: s) { store.toggle(id) }
    }
    @objc private func removed(_ b: NSButton) { if let s = b.identifier?.rawValue, let id = UUID(uuidString: s) { store.remove(id) } }
    @objc private func clearDone() { store.clearDone() }
}

final class FlippedView: NSView { override var isFlipped: Bool { true } }

/// The ⌥Space quick-capture box: one line, Enter saves, Esc cancels.
final class QuickNote: NSObject {
    let panel: KeyPanel
    private let field = NSTextField()
    var onSubmit: ((String) -> Void)?
    override init() {
        panel = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 340, height: 44),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.onEscape = { [weak self] in self?.panel.orderOut(nil) }
        let box = NSView(frame: NSRect(x: 0, y: 0, width: 340, height: 44))
        box.wantsLayer = true
        box.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        box.layer?.cornerRadius = 12
        box.layer?.borderWidth = 1.5
        box.layer?.borderColor = NSColor(calibratedWhite: 0.2, alpha: 0.9).cgColor
        field.frame = NSRect(x: 12, y: 10, width: 316, height: 24)
        field.placeholderString = "记一笔…（15:00 交报表 / 10分钟后 关火）"
        field.font = NSFont.systemFont(ofSize: 14)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.target = self
        field.action = #selector(submit)
        box.addSubview(field)
        panel.contentView = box
    }
    func show(above frame: NSRect) {
        var o = NSPoint(x: frame.midX - 170, y: frame.maxY + 6)
        if let vis = (NSScreen.screens.first { $0.frame.intersects(frame) } ?? NSScreen.main)?.visibleFrame {
            o.x = clamp(o.x, vis.minX + 4, vis.maxX - 344)
            o.y = clamp(o.y, vis.minY + 4, vis.maxY - 48)
        }
        panel.setFrameOrigin(o)
        field.stringValue = ""
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(field)
    }
    @objc private func submit() {
        let t = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        panel.orderOut(nil)
        if !t.isEmpty { onSubmit?(t) }
    }
}

// MARK: - Global hotkey (⌥Space) — Carbon hotkeys need no accessibility permission

private var hotKeyAction: (() -> Void)?
func registerHotKey(_ action: @escaping () -> Void) {
    hotKeyAction = action
    var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
    InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
        DispatchQueue.main.async { hotKeyAction?() }
        return noErr
    }, 1, &spec, nil, nil)
    var ref: EventHotKeyRef?
    let id = EventHotKeyID(signature: OSType(0x4755_5455), id: 1)   // "GUTU"
    RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey), id, GetApplicationEventTarget(), 0, &ref)
}

// MARK: - Clipboard history (kept in memory only; never written to disk)

final class ClipboardHistory {
    private(set) var items: [String] = []
    private var lastCount = NSPasteboard.general.changeCount
    private var ignoreCount = -1
    private let limit = 10
    func poll() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastCount else { return }
        lastCount = pb.changeCount
        if lastCount == ignoreCount { return }
        // Password managers mark secrets as concealed/transient: never keep those.
        let types = pb.types?.map { $0.rawValue } ?? []
        if types.contains("org.nspasteboard.ConcealedType") || types.contains("org.nspasteboard.TransientType") { return }
        guard let s = pb.string(forType: .string), !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        items.removeAll { $0 == s }
        items.insert(s, at: 0)
        if items.count > limit { items.removeLast(items.count - limit) }
    }
    func copyBack(_ i: Int) {
        guard items.indices.contains(i) else { return }
        let s = items[i]
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(s, forType: .string)
        ignoreCount = pb.changeCount
        lastCount = pb.changeCount
        items.remove(at: i); items.insert(s, at: 0)
    }
    func clear() { items.removeAll() }
}

// MARK: - Quiet mode: fullscreen video / meetings

enum Quiet {
    /// Apps whose being frontmost means "I'm in a call".
    static let meetingApps: Set<String> = [
        "us.zoom.xos", "com.microsoft.teams", "com.microsoft.teams2", "com.tencent.meeting",
        "com.apple.FaceTime", "Cisco-Systems.Spark", "com.cisco.webexmeetingsapp", "com.ringcentral.glip",
    ]
    static func shouldBeQuiet() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication else { return false }
        if let id = front.bundleIdentifier, meetingApps.contains(id) { return true }
        if front.bundleIdentifier == Bundle.main.bundleIdentifier { return false }
        // A normal-layer window of the frontmost app covering a whole screen = fullscreen video, slides, games.
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        let screens = NSScreen.screens.map { $0.frame.size }
        for w in list {
            guard (w[kCGWindowOwnerPID as String] as? Int32) == front.processIdentifier,
                  (w[kCGWindowLayer as String] as? Int) == 0,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  let width = b["Width"], let height = b["Height"] else { continue }
            if screens.contains(where: { abs($0.width - width) < 2 && abs($0.height - height) < 2 }) { return true }
        }
        return false
    }
}

// MARK: - Where to hide

/// Estimates the Dock's width from its settings (icon count × icon size) — macOS has no API for it
/// without accessibility permission — and returns the free strip to the right of it, if any.
enum Hideout {
    static func dockGap() -> NSRect? {
        if ProcessInfo.processInfo.environment["CATPETS_NOGAP"] != nil { return nil }   // debug: pretend the Dock is full width
        guard let screen = NSScreen.screens.first(where: { $0.frame.origin == .zero }) ?? NSScreen.main else { return nil }
        let f = screen.frame, v = screen.visibleFrame
        let stripH = v.minY - f.minY
        guard stripH >= 40 else { return nil }          // Dock hidden, or on the left/right edge
        func pref(_ k: String) -> Any? { CFPreferencesCopyAppValue(k as CFString, "com.apple.dock" as CFString) }
        let apps = pref("persistent-apps") as? [[String: Any]] ?? []
        let others = pref("persistent-others") as? [[String: Any]] ?? []
        let pinned = Set(apps.compactMap { (($0["tile-data"] as? [String: Any])?["bundle-identifier"] as? String) })
        let showRecents = (pref("show-recents") as? Bool) ?? true
        let recents = showRecents ? min(3, (pref("recent-apps") as? [Any])?.count ?? 0) : 0
        let running = NSWorkspace.shared.runningApplications.filter {
            $0.activationPolicy == .regular && !pinned.contains($0.bundleIdentifier ?? "") && $0.bundleIdentifier != "com.apple.finder"
        }.count
        let icons = Double(1 + apps.count + max(recents, running) + others.count + 1)   // Finder … Trash
        let tile = (pref("tilesize") as? Double) ?? 48
        let separators = (recents > 0 || running > 0) ? 2.0 : 1.0
        let dockW = (icons * (tile + 4) + separators * tile * 0.45 + tile * 0.8) * 1.08   // a little safety margin
        let gapW = (f.width - dockW) / 2 - 10
        guard gapW > 60 else { return nil }
        return NSRect(x: f.maxX - gapW, y: f.minY, width: gapW, height: stripH)
    }
}

// MARK: - App

final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var cats: [Cat] = []
    private var pairs: [Pair] = []
    private var pairPanel: CatPanel!
    private var pairView: PairView!
    private var meeting: Pair?                 // walking toward each other for this
    private var arrivedCats = Set<String>()
    private var activePair: Pair?
    private var pairStart = 0.0
    private var nextTogether = Double.infinity
    private var status: NSStatusItem!
    private var timer: Timer?
    private let settings = UserDefaults.standard
    private var paused = false, pauseAt = 0.0, pausedTotal = 0.0
    private var menuOpen = false
    var now: Double { (paused ? pauseAt : ProcessInfo.processInfo.systemUptime) - pausedTotal }
    var strolls: Bool { settings.bool(forKey: "strolls") && !isQuiet }
    private(set) var isQuiet = false
    private var autoQuiet: Bool { settings.bool(forKey: "autoQuiet") }
    /// "top" = always in front, "behind" = sits on the desktop under windows, "corner" = naps in a hideout.
    private var placement: String { settings.string(forKey: "placement") ?? "top" }
    private let behindLevel = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
    private var normalLevel: NSWindow.Level { placement == "behind" ? behindLevel : .floating }
    private var savedSpots: [String: NSPoint] = [:]
    private var lastQuietCheck = 0.0, lastSlowTick = 0.0
    /// While the user types, one cat taps on its laptop; they take turns.
    private var typeAlong: Bool { settings.bool(forKey: "typeAlong") }
    private var typist: Cat?, typistSince = 0.0
    private let launchedAt = ProcessInfo.processInfo.systemUptime
    private let bubble = Bubble()
    let todos = TodoStore()
    private lazy var todoWindow = TodoWindow(store: todos)
    private let quickNote = QuickNote()
    private let clipboard = ClipboardHistory()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let me = ProcessInfo.processInfo.processIdentifier
        if let other = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            .first(where: { $0.processIdentifier != me }) {
            other.activate(options: []); NSApp.terminate(nil); return
        }
        settings.register(defaults: ["scale": 1.0, "strolls": true, "autoQuiet": true, "typeAlong": true, "gravity": true])
        do {
            guard let root = Bundle.main.url(forResource: "cats", withExtension: nil) else {
                throw NSError(domain: "CatPets", code: 3, userInfo: [NSLocalizedDescriptionKey: "未找到应用内的猫咪图片。请保留完整的应用包。"])
            }
            let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: root.appendingPathComponent("manifest.json")))
            for spec in manifest.cats {
                let cat = try Cat(spec: spec, root: root, now: now)
                cat.owner = self
                cats.append(cat)
            }
            pairs = try (manifest.pairs ?? []).map { try Pair(spec: $0, root: root) }
        } catch {
            NSAlert(error: error).runModal()
            NSApp.terminate(nil); return
        }
        for cat in cats where !settings.bool(forKey: "hidden-\(cat.spec.id)") { cat.panel.orderFrontRegardless() }
        pairPanel = CatPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        pairPanel.isOpaque = false
        pairPanel.backgroundColor = .clear
        pairPanel.hasShadow = false
        pairPanel.level = normalLevel
        pairPanel.hidesOnDeactivate = false
        pairPanel.isReleasedWhenClosed = false
        pairPanel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        pairView = PairView(frame: .zero)
        pairView.owner = self
        pairView.toolTip = "单击让它们分开"
        pairPanel.contentView = pairView

        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "pawprint.fill", accessibilityDescription: "谷谷和团团")
        status.button?.toolTip = "谷谷和团团"
        status.button?.target = self
        status.button?.action = #selector(openStatusMenu)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged),
                                               name: NSApplication.didChangeScreenParametersNotification, object: nil)
        for c in cats { c.panel.level = normalLevel }
        quickNote.onSubmit = { [weak self] text in self?.addTodo(text) }
        // First launch of the day: both cats wake up with a big stretch.
        let today = DateFormatter.localizedString(from: Date(), dateStyle: .short, timeStyle: .none)
        if settings.string(forKey: "lastStretchDay") != today {
            settings.set(today, forKey: "lastStretchDay")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.cats.forEach { $0.wake() }
                self?.say("早上好～伸个懒腰再开工", seconds: 5)
            }
        }
        registerHotKey { [weak self] in self?.openQuickNote() }
        if ProcessInfo.processInfo.environment["CATPETS_OPEN"] == "todos" { DispatchQueue.main.async { self.openTodos() } }
        // Debug: CATPETS_DEMO=<action> plays it on both cats; CATPETS_SNAPCATS=<dir> saves what they show.
        if let demo = ProcessInfo.processInfo.environment["CATPETS_DEMO"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in self?.cats.forEach { $0.play(demo) } }
        }
        // Debug: CATPETS_DROPTEST lifts Gugu 400pt, lets go, and logs his height while he falls.
        if ProcessInfo.processInfo.environment["CATPETS_DROPTEST"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let cat = self?.cats.first, let vis = cat.panel.screen?.visibleFrame else { return }
                cat.beginDrag()
                cat.panel.setFrameOrigin(NSPoint(x: cat.panel.frame.minX, y: vis.minY + 400))
                cat.endDrag()
                for i in 0..<30 {
                    DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.05) {
                        FileHandle.standardError.write("drop \(i * 50)ms y=\(Int(cat.panel.frame.minY - vis.minY)) \(cat.action)\n".data(using: .utf8)!)
                    }
                }
            }
        }
        if let pid = ProcessInfo.processInfo.environment["CATPETS_PAIR"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                if let p = self?.pairs.first(where: { $0.spec.id == pid }) { self?.startPair(p) }
            }
        }
        if let dir = ProcessInfo.processInfo.environment["CATPETS_SNAPPAIR"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 25) { [weak self] in
                guard let v = self?.pairView, let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/pair.png"))
            }
        }
        if let dir = ProcessInfo.processInfo.environment["CATPETS_SNAPCATS"] {
            for (n, delay) in [3.2, 4.0, 4.8, 6.0].enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    for c in self?.cats ?? [] {
                        let v = c.view
                        guard let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { continue }
                        v.cacheDisplay(in: v.bounds, to: rep)
                        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(c.spec.id)-\(n).png"))
                    }
                }
            }
        }
        if let out = ProcessInfo.processInfo.environment["CATPETS_SNAP"] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                guard let v = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeKey })?.contentView,
                      let rep = v.bitmapImageRepForCachingDisplay(in: v.bounds) else { return }
                v.cacheDisplay(in: v.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
            }
        }
        if ProcessInfo.processInfo.environment["CATPETS_OPEN"] == "note" { DispatchQueue.main.async { self.openQuickNote() } }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = 0.006
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        slowTick()
        guard !paused, !menuOpen else { return }
        let t = now
        for cat in cats where cat.panel.isVisible { cat.tick(t) }
        if nextTogether == .infinity { nextTogether = t + Double.random(in: 480...900) }
        if activePair == nil, meeting == nil, t > nextTogether, strolls,
           cats.allSatisfy({ $0.panel.isVisible && $0.isIdle && $0.action == "idle" }),
           let group = pairGroups.filter({ $0.key != "sleep" }).randomElement(), let pick = randomVariant(group.key) {
            nextTogether = t + Double.random(in: 480...900)
            startPair(pick)
        }
        if let p = activePair {
            pairView.needsDisplay = true
            if let secs = p.spec.seconds, t - pairStart > secs { endPair() }
        }
    }

    // MARK: Tools

    /// Twice a second: reminders, clipboard, bubbles and quiet-mode checks (also while paused).
    private func slowTick() {
        let real = ProcessInfo.processInfo.systemUptime
        bubble.tick()
        guard real - lastSlowTick > 0.5 else { return }
        lastSlowTick = real
        clipboard.poll()
        for t in todos.takeDue() { remind(t) }
        if real - lastQuietCheck > 2 {
            lastQuietCheck = real
            let want = placement == "corner" || (autoQuiet && Quiet.shouldBeQuiet())
            if ProcessInfo.processInfo.environment["CATPETS_DEBUG"] != nil { print("quiet check:", autoQuiet, want, isQuiet) }
            if want != isQuiet { want ? enterQuiet() : leaveQuiet() }
        }
        typeAlongTick()
    }
    /// Which cat speaks: Gugu for reminders, whichever is visible otherwise.
    private var speaker: Cat? { cats.first { $0.panel.isVisible } }
    private var speakFrame: NSRect { activePair != nil ? pairPanel.frame : (speaker?.panel.frame ?? NSScreen.main?.visibleFrame ?? .zero) }
    func say(_ text: String, seconds: Double = 10) { bubble.say(text, above: speakFrame, seconds: seconds) }

    private func remind(_ t: Todo) {
        NSSound(named: "Glass")?.play()
        if activePair == nil, !isQuiet { speaker?.hop() }
        say("⏰ \(t.text)", seconds: 30)
    }
    func addTodo(_ text: String) {
        guard let t = todos.add(text) else { return }
        if let d = t.due { say("记下了～ \(dueLabel(d)) 提醒你：\(t.text)", seconds: 5) }
        else { say("记下了：\(t.text)", seconds: 4) }
    }
    @objc func openQuickNote() { quickNote.show(above: speakFrame) }
    @objc func openTodos() { todoWindow.show(near: speakFrame) }
    @objc private func copyClip(_ s: NSMenuItem) { clipboard.copyBack(s.tag); say("已复制，可以粘贴啦", seconds: 2) }
    @objc private func clearClips() { clipboard.clear() }
    /// Reads only how long ago a key was pressed (no key contents, no extra permission).
    private func typeAlongTick() {
        let env = ProcessInfo.processInfo.environment
        var idleFor = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .keyDown)
        if let fake = env["CATPETS_FAKETYPING"], let stop = Double(fake) {   // debug: "typing" for the first N seconds
            idleFor = ProcessInfo.processInfo.systemUptime - launchedAt < stop ? 0 : 99
        }
        guard idleFor < 1.5, typeAlong, !paused, !isQuiet, activePair == nil, meeting == nil else {
            // In step with the keyboard: when the typing stops, so does the cat.
            if let c = typist, c.action == "laptop" { c.play("idle") }
            if typist != nil, env["CATPETS_DEBUG"] != nil { FileHandle.standardError.write("typist: stop\n".data(using: .utf8)!) }
            typist = nil
            return
        }
        let ready = cats.filter { $0.panel.isVisible && !$0.isBusy && $0.actions["laptop"] != nil }
        guard !ready.isEmpty else { typist = nil; return }
        let t = now
        if let c = typist, ready.contains(where: { $0 === c }), t - typistSince < 15 {
            // Still this cat's turn: start another round once the last one has finished.
            if c.action == "idle" || c.action == "sleep" { c.play("laptop") }
            return
        }
        // Hand over to the other cat (or start with whoever is free).
        let prev = typist
        let next = ready.first { $0 !== prev } ?? ready[0]
        if let p = prev, p !== next, p.action == "laptop" { p.play("idle") }
        typist = next
        typistSince = t
        if env["CATPETS_DEBUG"] != nil { FileHandle.standardError.write("typist: \(next.spec.id) \(Int(t))\n".data(using: .utf8)!) }
        if next.action != "laptop" { next.play("laptop") }
    }
    @objc private func toggleTypeAlong() {
        settings.set(!typeAlong, forKey: "typeAlong")
        if !typeAlong, let c = typist, c.action == "laptop" { c.play("idle") }
    }
    @objc private func toggleAutoQuiet() {
        settings.set(!autoQuiet, forKey: "autoQuiet")
        if !autoQuiet && isQuiet { leaveQuiet() }
    }

    /// Fullscreen video, a call, or the "hide in the corner" setting: both cats curl up asleep out of the way.
    /// If there's free room beside the Dock they shrink into it; otherwise they nap behind the windows.
    private func enterQuiet() {
        isQuiet = true
        meeting = nil
        if activePair != nil { endPair() }
        if savedSpots.isEmpty {
            savedSpots = Dictionary(uniqueKeysWithValues: cats.map { ($0.spec.id, $0.panel.frame.origin) })
        }
        let visible = cats.filter { $0.panel.isVisible }
        for cat in visible { cat.cancelWalk(); cat.play(cat.actions["sleep"] != nil ? "sleep" : "idle") }
        let pad = 8.0
        if let gap = Hideout.dockGap() {
            // Shrink both by the same factor so the tallest sleeping cat fits the strip height.
            let tallest = visible.map { $0.sleepFootprint(scale: 1).height }.max() ?? 1
            let k = min(settings.double(forKey: "scale"), (gap.height - pad) / tallest)
            let widths = visible.map { $0.sleepFootprint(scale: k).width }
            if k > 0.25, widths.reduce(0, +) + pad * Double(widths.count + 1) <= gap.width {
                var right = gap.maxX - pad
                for (cat, w) in zip(visible, widths) {
                    cat.sizeOverride = k
                    cat.place(midX: right - w / 2, bottom: gap.minY + 3)
                    cat.panel.level = .floating
                    cat.panel.alphaValue = 1
                    right -= w + pad
                }
                return
            }
        }
        // No room beside the Dock: nap in the bottom-right corner, underneath every window.
        let vis = NSScreen.main?.visibleFrame ?? .zero
        var right = vis.maxX - pad
        for cat in visible {
            cat.sizeOverride = nil
            let w = cat.sleepFootprint(scale: cat.size).width
            cat.place(midX: right - w / 2, bottom: vis.minY)
            cat.panel.level = behindLevel
            cat.panel.alphaValue = 1
            right -= w + pad
        }
    }
    private func leaveQuiet() {
        isQuiet = false
        for cat in cats {
            cat.sizeOverride = nil
            cat.resize()
            if let p = savedSpots[cat.spec.id] { cat.panel.setFrameOrigin(p); cat.keepOnScreen() }
            cat.panel.level = normalLevel
            cat.panel.alphaValue = 1
            if cat.panel.isVisible { cat.play("idle") }
        }
        savedSpots = [:]
    }
    @objc private func setPlacement(_ s: NSMenuItem) {
        guard let p = s.representedObject as? String else { return }
        settings.set(p, forKey: "placement")
        pairPanel.level = normalLevel
        if p == "corner" {
            enterQuiet()
        } else {
            if isQuiet { leaveQuiet() }
            for c in cats { c.panel.level = normalLevel }
        }
    }

    // MARK: Together

    private var gugu: Cat? { cats.first { $0.spec.id == "gugu" } }
    private var tuantuan: Cat? { cats.first { $0.spec.id == "tuantuan" } }

    /// Both cats walk to the middle point between them, then the two-cat animation takes over.
    func startPair(_ pair: Pair) {
        guard activePair == nil, let g = gugu, let w = tuantuan else { return }
        for c in [g, w] where !c.panel.isVisible { show(c) }
        guard !g.isBusy, !w.isBusy else { return }
        let vis = (g.panel.screen ?? NSScreen.main)?.visibleFrame ?? .zero
        let half = pair.size(scale: settings.double(forKey: "scale")).width / 2
        let mid = clamp((g.panel.frame.midX + w.panel.frame.midX) / 2, vis.minX + half, vis.maxX - half)
        // Gugu on the left, Tuantuan on the right, nearly touching.
        let gap = (g.panel.frame.width + w.panel.frame.width) * 0.18
        meeting = pair
        arrivedCats = []
        g.walk(toX: mid - gap)
        w.walk(toX: mid + gap)
    }
    func arrived(_ cat: Cat) {
        guard let pair = meeting else { return }
        arrivedCats.insert(cat.spec.id)
        guard arrivedCats.count == cats.count else { return }
        meeting = nil
        let scale = settings.double(forKey: "scale")
        let size = pair.size(scale: scale)
        let midX = cats.map { $0.panel.frame.midX }.reduce(0, +) / Double(cats.count)
        let y = cats.map { $0.panel.frame.minY }.min() ?? 0
        pairPanel.setFrame(NSRect(x: midX - size.width / 2, y: y, width: size.width, height: size.height), display: false)
        let start = now
        pairView.draw = { [weak self] ctx, bounds in
            guard let self = self else { return }
            pair.draw(in: ctx, bounds: bounds, t: self.now - start, scale: scale)
        }
        for c in cats { c.panel.orderOut(nil) }
        activePair = pair
        pairStart = start
        pairPanel.orderFrontRegardless()
    }
    func meetingCancelled() {
        meeting = nil
        for c in cats { c.cancelWalk() }
    }
    func endPair() {
        guard activePair != nil else { return }
        activePair = nil
        let f = pairPanel.frame
        pairPanel.orderOut(nil)
        if let g = gugu { g.panel.setFrameOrigin(NSPoint(x: f.midX - g.panel.frame.width * 0.95, y: f.minY)) }
        if let w = tuantuan { w.panel.setFrameOrigin(NSPoint(x: f.midX - w.panel.frame.width * 0.05, y: f.minY)) }
        for c in cats { show(c); c.play("idle"); c.savePosition() }
    }
    /// Called when a cat is about to nap: if the other one is idle nearby, nap together instead.
    func wantsCuddle(from cat: Cat) -> Bool {
        guard !isQuiet, activePair == nil, meeting == nil, let pair = randomVariant("sleep"),
              let other = cats.first(where: { $0 !== cat }), other.panel.isVisible, other.isIdle,
              abs(other.panel.frame.midX - cat.panel.frame.midX) < 600 else { return false }
        startPair(pair)
        return true
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        func add(_ title: String, _ sel: Selector?, to m: NSMenu = menu, tag: Int = 0, rep: Any? = nil, on: Bool? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            item.target = sel == nil ? nil : self
            item.tag = tag
            item.representedObject = rep
            if let on = on { item.state = on ? .on : .off }
            m.addItem(item)
            return item
        }
        func sub(_ title: String, _ build: (NSMenu) -> Void) {
            let item = add(title, #selector(noop))
            let m = NSMenu()
            build(m)
            item.submenu = m
        }
        _ = add(isQuiet ? "谷谷和团团 · 安静中 zzz" : (paused ? "谷谷和团团 · 已暂停" : "谷谷和团团"), nil)
        menu.addItem(.separator())

        // Tools
        let n = todos.openCount
        _ = add(n > 0 ? "📝 待办（\(n)）…" : "📝 待办…", #selector(openTodos))
        let quick = add("✏️ 记一笔", #selector(openQuickNote))
        quick.keyEquivalent = " "
        quick.keyEquivalentModifierMask = [.option]
        sub("📋 剪贴板历史") { m in
            if clipboard.items.isEmpty { _ = add("还没有复制过文字", nil, to: m) }
            for (i, c) in clipboard.items.enumerated() {
                var line = c.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
                if line.count > 36 { line = String(line.prefix(36)) + "…" }
                _ = add(line, #selector(copyClip(_:)), to: m, tag: i)
            }
            if !clipboard.items.isEmpty { m.addItem(.separator()); _ = add("清空记录", #selector(clearClips), to: m) }
        }
        menu.addItem(.separator())

        // Cats
        for (i, cat) in cats.enumerated() {
            sub("🐱 " + cat.spec.name) { m in
                for key in cat.spec.order where cat.actions[key] != nil {
                    _ = add(cat.spec.actions[key]!.label, #selector(playAction(_:)), to: m, tag: i, rep: key)
                }
                if cat.actions["walk"] != nil { _ = add("散步", #selector(strollCat(_:)), to: m, tag: i) }
            }
        }
        if !pairs.isEmpty {
            sub("💞 一起") { m in
                for (i, g) in pairGroups.enumerated() { _ = add(g.label, #selector(playPair(_:)), to: m, tag: i) }
            }
        }
        menu.addItem(.separator())

        // Settings
        sub("⚙️ 设置") { m in
            let sizeItem = add("大小", #selector(noop), to: m)
            let sizes = NSMenu()
            for pct in [70, 85, 100, 125, 150] {
                _ = add("\(pct)%" + (pct == 100 ? "（默认）" : ""), #selector(resize(_:)), to: sizes, tag: pct,
                        on: abs(settings.double(forKey: "scale") * 100 - Double(pct)) < 1)
            }
            sizeItem.submenu = sizes
            let placeItem = add("位置", #selector(noop), to: m)
            let places = NSMenu()
            for (key, title) in [("top", "总在最前"), ("behind", "不置顶（会被窗口挡住）"), ("corner", "藏在角落睡觉")] {
                _ = add(title, #selector(setPlacement(_:)), to: places, rep: key, on: placement == key)
            }
            placeItem.submenu = places
            _ = add("偶尔自己散步、凑一起", #selector(toggleStrolls), to: m, on: settings.bool(forKey: "strolls"))
            _ = add("全屏 / 开会时自动安静", #selector(toggleAutoQuiet), to: m, on: autoQuiet)
            _ = add("我打字时，它们轮流敲电脑", #selector(toggleTypeAlong), to: m, on: typeAlong)
            _ = add("拖到半空松手会掉下来", #selector(toggleGravity), to: m, on: settings.bool(forKey: "gravity"))
            m.addItem(.separator())
            for (i, cat) in cats.enumerated() {
                _ = add("显示\(cat.spec.name)", #selector(toggleCat(_:)), to: m, tag: i, on: cat.panel.isVisible || activePair != nil)
            }
            m.addItem(.separator())
            _ = add("玩法：单击互动 · 拖动搬家 · ⌥空格 记一笔", nil, to: m)
        }
        _ = add(paused ? "▶️ 继续活动" : "⏸ 暂停活动", #selector(togglePause))
        _ = add("🏠 把两只猫叫回右下角", #selector(resetPositions))
        menu.addItem(.separator())
        _ = add("退出", #selector(quit))
        return menu
    }
    func menuWillOpen(_ menu: NSMenu) { menuOpen = true }
    func menuDidClose(_ menu: NSMenu) { menuOpen = false }

    @objc private func noop() {}
    @objc private func openStatusMenu() {
        guard let b = status.button else { return }
        makeMenu().popUp(positioning: nil, at: NSPoint(x: 0, y: b.bounds.minY - 3), in: b)
    }
    private func show(_ cat: Cat) {
        if activePair != nil { endPair() }   // asking for one cat splits the pair up first
        cat.keepOnScreen(); cat.panel.orderFrontRegardless()
        settings.set(false, forKey: "hidden-\(cat.spec.id)")
    }
    @objc private func playAction(_ s: NSMenuItem) {
        if paused { togglePause() }
        let cat = cats[s.tag]; show(cat); cat.play(s.representedObject as! String)
    }
    @objc private func strollCat(_ s: NSMenuItem) { if paused { togglePause() }; show(cats[s.tag]); cats[s.tag].stroll() }
    /// Menu entries: one per group, in manifest order; each plays a random variant.
    private var pairGroups: [(key: String, label: String)] {
        var seen = Set<String>(), out: [(key: String, label: String)] = []
        for p in pairs {
            let key = p.spec.group ?? p.spec.id
            if seen.insert(key).inserted { out.append((key, p.spec.label)) }
        }
        return out
    }
    private func randomVariant(_ key: String) -> Pair? { pairs.filter { ($0.spec.group ?? $0.spec.id) == key }.randomElement() }
    @objc private func playPair(_ s: NSMenuItem) {
        if paused { togglePause() }
        if activePair != nil { endPair() }
        if let p = randomVariant(pairGroups[s.tag].key) { startPair(p) }
    }
    @objc private func toggleGravity() { settings.set(!settings.bool(forKey: "gravity"), forKey: "gravity") }
    @objc private func toggleStrolls() { settings.set(!settings.bool(forKey: "strolls"), forKey: "strolls") }
    @objc private func toggleCat(_ s: NSMenuItem) {
        let cat = cats[s.tag]
        if cat.panel.isVisible { cat.panel.orderOut(nil); settings.set(true, forKey: "hidden-\(cat.spec.id)") } else { show(cat) }
    }
    @objc private func resize(_ s: NSMenuItem) {
        settings.set(Double(s.tag) / 100, forKey: "scale")
        for cat in cats { cat.resize(); cat.savePosition() }
    }
    @objc private func togglePause() {
        let real = ProcessInfo.processInfo.systemUptime
        if paused { pausedTotal += real - pauseAt } else { pauseAt = real }
        paused.toggle()
    }
    @objc private func resetPositions() {
        if placement == "corner" { settings.set("top", forKey: "placement"); pairPanel.level = normalLevel }
        if isQuiet { leaveQuiet() }
        let vis = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        var x = vis.maxX - 60
        for cat in cats {
            x -= cat.panel.frame.width
            cat.panel.setFrameOrigin(NSPoint(x: x, y: vis.minY))
            show(cat); cat.savePosition()
            x -= 10
        }
    }
    @objc private func screensChanged() {
        if isQuiet { enterQuiet(); return }
        for cat in cats { cat.keepOnScreen(); cat.savePosition() }
    }
    @objc private func quit() { NSApp.terminate(nil) }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        for cat in cats { show(cat) }
        return true
    }
    func applicationWillTerminate(_ notification: Notification) { for cat in cats { cat.savePosition() } }
}

let app = NSApplication.shared
let controller = AppController()
app.delegate = controller
app.setActivationPolicy(.accessory)
app.run()
