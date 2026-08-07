import AppKit

// Genera l'icona dell'app: pellicola stilizzata su gradiente scuro con play rosso.
func draw(size: CGFloat) -> Data? {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    guard let ctx = NSGraphicsContext.current?.cgContext else { img.unlockFocus(); return nil }

    let r = size * 0.2237
    let rect = CGRect(x: 0, y: 0, width: size, height: size)
    let path = CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
    ctx.addPath(path)
    ctx.clip()

    let colors = [NSColor(calibratedRed: 0.13, green: 0.14, blue: 0.18, alpha: 1).cgColor,
                  NSColor(calibratedRed: 0.05, green: 0.05, blue: 0.07, alpha: 1).cgColor]
    if let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(),
                             colors: colors as CFArray, locations: [0, 1]) {
        ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: size),
                               end: CGPoint(x: size, y: 0), options: [])
    }

    // fori della pellicola
    let holeW = size * 0.062, holeH = size * 0.085
    let inset = size * 0.052
    NSColor(calibratedWhite: 1, alpha: 0.14).setFill()
    for i in 0..<5 {
        let y = size * 0.115 + CGFloat(i) * size * 0.1925
        for x in [inset, size - inset - holeW] {
            let p = NSBezierPath(roundedRect: CGRect(x: x, y: y, width: holeW, height: holeH),
                                 xRadius: holeW * 0.28, yRadius: holeW * 0.28)
            p.fill()
        }
    }

    // triangolo play
    let cx = size * 0.5, cy = size * 0.5, s = size * 0.235
    let tri = NSBezierPath()
    tri.move(to: NSPoint(x: cx - s * 0.72, y: cy + s))
    tri.line(to: NSPoint(x: cx + s * 0.98, y: cy))
    tri.line(to: NSPoint(x: cx - s * 0.72, y: cy - s))
    tri.close()
    tri.lineJoinStyle = .round
    tri.lineWidth = size * 0.055
    NSColor(calibratedRed: 0.92, green: 0.13, blue: 0.18, alpha: 1).setFill()
    NSColor(calibratedRed: 0.92, green: 0.13, blue: 0.18, alpha: 1).setStroke()
    tri.fill()
    tri.stroke()

    img.unlockFocus()

    guard let tiff = img.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff) else { return nil }
    rep.size = NSSize(width: size, height: size)
    return rep.representation(using: .png, properties: [:])
}

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "./iconset"
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
for (size, name) in [(16, "16x16"), (32, "16x16@2x"), (32, "32x32"), (64, "32x32@2x"),
                     (128, "128x128"), (256, "128x128@2x"), (256, "256x256"),
                     (512, "256x256@2x"), (512, "512x512"), (1024, "512x512@2x")] {
    if let data = draw(size: CGFloat(size)) {
        try? data.write(to: URL(fileURLWithPath: "\(out)/icon_\(name).png"))
    }
}
print("icone generate in \(out)")
