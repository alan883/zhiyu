// Renders 指语 app icon (1024px) and menubar template glyph. Usage: swift logo.swift <outdir>
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

func cg(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
}

// Classic pointer arrow, tip at origin, y grows downward, height ~1.0
func arrowPath(at o: CGPoint, scale s: CGFloat) -> CGPath {
    let pts: [(CGFloat, CGFloat)] = [(0, 0), (0, 0.86), (0.215, 0.665), (0.355, 0.985), (0.5, 0.92), (0.36, 0.605), (0.64, 0.605)]
    let p = CGMutablePath()
    for (i, (x, y)) in pts.enumerated() {
        let q = CGPoint(x: o.x + x * s, y: o.y + y * s)
        i == 0 ? p.move(to: q) : p.addLine(to: q)
    }
    p.closeSubpath()
    return p
}

func render(size: Int, draw: (CGContext, CGFloat) -> Void) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    let c = ctx.cgContext
    c.translateBy(x: 0, y: CGFloat(size)); c.scaleBy(x: 1, y: -1)   // top-left origin
    c.setShouldAntialias(true)
    draw(c, CGFloat(size))
    ctx.flushGraphics()
    return rep
}

func save(_ rep: NSBitmapImageRep, _ name: String) {
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out + "/" + name))
}

// ---------- App icon ----------
let icon = render(size: 1024) { c, S in
    let rect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = CGPath(roundedRect: rect, cornerWidth: 186, cornerHeight: 186, transform: nil)

    // drop shadow
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: 18), blur: 28, color: cg(0x0B0620, 0.30))
    c.addPath(squircle); c.setFillColor(cg(0x2A1B6E)); c.fillPath()
    c.restoreGState()

    c.saveGState()
    c.addPath(squircle); c.clip()
    // base diagonal gradient: deep indigo -> violet -> cyan
    let base = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [cg(0x1B1050), cg(0x5B3BEA), cg(0x8F5BFF), cg(0x22D3EE)] as CFArray,
                          locations: [0, 0.45, 0.7, 1])!
    c.drawLinearGradient(base, start: CGPoint(x: 160, y: 960), end: CGPoint(x: 900, y: 80), options: [])
    // soft glow behind the arrow tip
    let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [cg(0xFFFFFF, 0.38), cg(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    c.drawRadialGradient(glow, startCenter: CGPoint(x: 420, y: 400), startRadius: 0,
                         endCenter: CGPoint(x: 420, y: 400), endRadius: 420, options: [])
    // top sheen
    let sheen = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [cg(0xFFFFFF, 0.22), cg(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 520), options: [])

    // voice ripples radiating from the arrow tip toward upper-right
    let tip = CGPoint(x: 352, y: 400)
    for (i, r) in [CGFloat(120), 200, 280].enumerated() {
        c.saveGState()
        c.setLineCap(.round)
        c.setLineWidth(40 - CGFloat(i) * 6)
        c.setStrokeColor(cg(0xFFFFFF, 0.95 - CGFloat(i) * 0.27))
        c.addArc(center: tip, radius: r, startAngle: -.pi * 0.40, endAngle: -.pi * 0.02, clockwise: false)
        c.strokePath()
        c.restoreGState()
    }

    // pointer arrow with shadow, white-to-mist fill, subtle rim
    let arrow = arrowPath(at: tip, scale: 420)
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: 22), blur: 40, color: cg(0x10063A, 0.55))
    c.addPath(arrow); c.setFillColor(cg(0xFFFFFF)); c.fillPath()
    c.restoreGState()
    c.saveGState()
    c.addPath(arrow); c.clip()
    let fill = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [cg(0xFFFFFF), cg(0xE6E1FF)] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(fill, start: CGPoint(x: tip.x, y: tip.y), end: CGPoint(x: tip.x + 200, y: tip.y + 420), options: [])
    c.restoreGState()
    c.addPath(arrow); c.setStrokeColor(cg(0x3A2A9A, 0.35)); c.setLineWidth(5); c.setLineJoin(.round); c.strokePath()

    c.restoreGState()
    // hairline inner border for crispness on light backgrounds
    c.addPath(CGPath(roundedRect: rect.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 185, cornerHeight: 185, transform: nil))
    c.setStrokeColor(cg(0xFFFFFF, 0.18)); c.setLineWidth(3); c.strokePath()
}
save(icon, "icon_1024.png")

// ---------- Menubar template glyph (black on transparent, 36px = 18pt @2x) ----------
let glyph = render(size: 36) { c, S in
    let tip = CGPoint(x: 9, y: 7)
    c.setFillColor(cg(0x000000))
    c.addPath(arrowPath(at: tip, scale: 22)); c.fillPath()
    c.setStrokeColor(cg(0x000000)); c.setLineCap(.round)
    for (i, r) in [CGFloat(9), 15].enumerated() {
        c.setLineWidth(2.6 - CGFloat(i) * 0.4)
        c.addArc(center: tip, radius: r, startAngle: -.pi * 0.45, endAngle: .pi * 0.02, clockwise: false)
        c.strokePath()
    }
}
save(glyph, "menubar@2x.png")
print("ok")
