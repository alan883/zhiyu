// Renders 指语 app icon (1024px) and menubar template glyph. Usage: swift logo.swift <outdir>
// Look: dark squircle with five rounded voice bars (borrowed from GPT Voice), violet glow for 指语 identity.
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

func cg(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: a)
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

/// Five rounded bars, heights as fractions of `h`, centred at `cx`.
func bars(_ c: CGContext, cx: CGFloat, cy: CGFloat, h: CGFloat, width: CGFloat, gap: CGFloat,
          heights: [CGFloat], color: CGColor) {
    let count = CGFloat(heights.count)
    let totalW = count * width + (count - 1) * gap
    var x = cx - totalW / 2
    c.setFillColor(color)
    for f in heights {
        let bh = max(width, h * f)
        let r = CGRect(x: x, y: cy - bh / 2, width: width, height: bh)
        c.addPath(CGPath(roundedRect: r, cornerWidth: width / 2, cornerHeight: width / 2, transform: nil))
        c.fillPath()
        x += width + gap
    }
}

// ---------- App icon ----------
let weights: [CGFloat] = [0.42, 0.66, 1.0, 0.66, 0.42]
let icon = render(size: 1024) { c, S in
    let rect = CGRect(x: 100, y: 100, width: 824, height: 824)
    let squircle = CGPath(roundedRect: rect, cornerWidth: 186, cornerHeight: 186, transform: nil)

    // drop shadow
    c.saveGState()
    c.setShadow(offset: CGSize(width: 0, height: 18), blur: 28, color: cg(0x05030C, 0.35))
    c.addPath(squircle); c.setFillColor(cg(0x121018)); c.fillPath()
    c.restoreGState()

    c.saveGState()
    c.addPath(squircle); c.clip()
    // near-black, cool at the top, warm violet at the bottom
    let base = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [cg(0x2A2733), cg(0x14121A), cg(0x1A1330)] as CFArray,
                          locations: [0, 0.55, 1])!
    c.drawLinearGradient(base, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 948), options: [])
    // soft violet glow behind the bars
    let glow = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                          colors: [cg(0x8F5BFF, 0.55), cg(0x8F5BFF, 0)] as CFArray, locations: [0, 1])!
    c.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 512), startRadius: 0,
                         endCenter: CGPoint(x: 512, y: 512), endRadius: 470, options: [])
    // top sheen
    let sheen = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                           colors: [cg(0xFFFFFF, 0.10), cg(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    c.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 100), end: CGPoint(x: 512, y: 470), options: [])

    // five voice bars
    bars(c, cx: 512, cy: 512, h: 430, width: 64, gap: 46,
         heights: weights, color: cg(0xF5F5F7))
    c.restoreGState()

    // hairline inner border
    c.addPath(CGPath(roundedRect: rect.insetBy(dx: 1.5, dy: 1.5), cornerWidth: 185, cornerHeight: 185, transform: nil))
    c.setStrokeColor(cg(0xFFFFFF, 0.12)); c.setLineWidth(3); c.strokePath()
}
save(icon, "icon_1024.png")

// ---------- Menubar template glyph (black on transparent, 36px = 18pt @2x) ----------
let glyph = render(size: 36) { c, S in
    bars(c, cx: 18, cy: 18, h: 24, width: 3.2, gap: 2.6,
         heights: weights, color: cg(0x000000))
}
save(glyph, "menubar@2x.png")
print("ok")
