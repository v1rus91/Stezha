import AppKit
// usage: icon.swift <oblasts.json> <out.png>
let S: CGFloat = 1024
let raw = try! JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: [[Double]]]
let img = NSImage(size: NSSize(width: S, height: S))
img.lockFocus()
let ctx = NSGraphicsContext.current!.cgContext
let rect = NSRect(x: 100, y: 100, width: 824, height: 824)
let sq = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGraphicsContext.current?.saveGraphicsState()
let sh = NSShadow(); sh.shadowColor = NSColor.black.withAlphaComponent(0.35); sh.shadowBlurRadius = 30; sh.shadowOffset = NSSize(width: 0, height: -12); sh.set()
NSGradient(colors: [NSColor(red: 0.09, green: 0.11, blue: 0.2, alpha: 1), NSColor(red: 0.02, green: 0.03, blue: 0.07, alpha: 1)])!.draw(in: sq, angle: -90)
NSGraphicsContext.current?.restoreGraphicsState()
NSGraphicsContext.current?.saveGraphicsState()
sq.addClip()
// projection
let pts = raw.values.flatMap { $0 }
let minX = pts.map { $0[0] }.min()!, maxX = pts.map { $0[0] }.max()!, minY = pts.map { $0[1] }.min()!, maxY = pts.map { $0[1] }.max()!
let kx = cos(48.5 * Double.pi / 180)
let w = (maxX - minX) * kx, h = maxY - minY
let scale = 700 / w
let ox = (S - w * scale) / 2, oy = (S - h * scale) / 2 + 20
func P(_ p: [Double]) -> CGPoint { CGPoint(x: ox + (p[0] - minX) * kx * scale, y: oy + (p[1] - minY) * scale) }
let all = CGMutablePath()
var paths: [String: CGPath] = [:]
for (n, ring) in raw {
    let p = CGMutablePath(); p.move(to: P(ring[0])); ring.dropFirst().forEach { p.addLine(to: P($0)) }; p.closeSubpath()
    paths[n] = p; all.addPath(p)
}
// flag fill: blue top half, yellow bottom half
ctx.saveGState(); ctx.addPath(all); ctx.clip()
let mid = oy + h * scale * 0.5
ctx.setFillColor(NSColor(red: 0.0, green: 0.36, blue: 0.85, alpha: 1).cgColor); ctx.fill(CGRect(x: 0, y: mid, width: S, height: S))
ctx.setFillColor(NSColor(red: 1.0, green: 0.82, blue: 0.0, alpha: 1).cgColor); ctx.fill(CGRect(x: 0, y: 0, width: S, height: mid))
ctx.restoreGState()
// borders
ctx.setStrokeColor(NSColor(red: 0.04, green: 0.05, blue: 0.1, alpha: 0.55).cgColor); ctx.setLineWidth(3)
for p in paths.values { ctx.addPath(p) }; ctx.strokePath()
// alert ping on Cherkasy
let c = P([32.06, 49.44])
for (r, a) in [(170.0, 0.12), (115.0, 0.22), (65.0, 0.45)] {
    ctx.setFillColor(NSColor(red: 1, green: 0.2, blue: 0.18, alpha: a).cgColor)
    ctx.fillEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
}
ctx.setFillColor(NSColor(red: 1, green: 0.23, blue: 0.19, alpha: 1).cgColor)
ctx.fillEllipse(in: CGRect(x: c.x - 30, y: c.y - 30, width: 60, height: 60))
ctx.setFillColor(NSColor.white.cgColor)
ctx.fillEllipse(in: CGRect(x: c.x - 11, y: c.y - 11, width: 22, height: 22))
NSGradient(colors: [NSColor.white.withAlphaComponent(0.14), NSColor.white.withAlphaComponent(0)])!.draw(in: NSRect(x: 100, y: 560, width: 824, height: 364), angle: -90)
NSGraphicsContext.current?.restoreGraphicsState()
img.unlockFocus()
let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
