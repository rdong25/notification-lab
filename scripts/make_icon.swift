// Renders the app icon: a warm squircle with a white bell and a red badge dot.
import AppKit

let out = CommandLine.arguments[1]
let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext

// macOS icon grid: 824pt body centered in a 1024 canvas.
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let path = CGPath(roundedRect: body, cornerWidth: 185, cornerHeight: 185, transform: nil)

ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: NSColor.black.withAlphaComponent(0.3).cgColor)
ctx.addPath(path); ctx.setFillColor(NSColor.black.cgColor); ctx.fillPath()
ctx.restoreGState()

ctx.saveGState()
ctx.addPath(path); ctx.clip()
let colors = [NSColor(red: 1.00, green: 0.62, blue: 0.33, alpha: 1).cgColor,
              NSColor(red: 0.93, green: 0.33, blue: 0.27, alpha: 1).cgColor] as CFArray
let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 0, y: 924), end: CGPoint(x: 0, y: 100), options: [])
// soft top highlight
ctx.setFillColor(NSColor.white.withAlphaComponent(0.10).cgColor)
ctx.fillEllipse(in: CGRect(x: -100, y: 560, width: 1224, height: 700))
ctx.restoreGState()

// bell glyph
let config = NSImage.SymbolConfiguration(pointSize: 470, weight: .semibold)
if let bell = NSImage(systemSymbolName: "bell.fill", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
    let tinted = NSImage(size: bell.size)
    tinted.lockFocus()
    bell.draw(at: .zero, from: .zero, operation: .sourceOver, fraction: 1)
    NSColor.white.set()
    NSRect(origin: .zero, size: bell.size).fill(using: .sourceAtop)
    tinted.unlockFocus()
    let r = CGRect(x: (size - bell.size.width) / 2, y: (size - bell.size.height) / 2 - 10,
                   width: bell.size.width, height: bell.size.height)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 18, color: NSColor.black.withAlphaComponent(0.18).cgColor)
    tinted.draw(in: r)
    ctx.restoreGState()
}

// badge dot
let dot = CGRect(x: 610, y: 600, width: 190, height: 190)
ctx.setFillColor(NSColor.white.cgColor); ctx.fillEllipse(in: dot.insetBy(dx: -18, dy: -18))
ctx.setFillColor(NSColor(red: 0.85, green: 0.12, blue: 0.20, alpha: 1).cgColor); ctx.fillEllipse(in: dot)

image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
