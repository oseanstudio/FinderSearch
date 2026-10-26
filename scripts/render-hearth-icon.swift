import AppKit

// HOMY: Hearth's icon, drawn programmatically — a warm tile, a white house,
// and a magnifying glass for a door: a home for your files with search built
// in. Usage: render-hearth-icon.swift output.png size

guard CommandLine.arguments.count == 3,
    let size = Int(CommandLine.arguments[2]), size > 0,
    let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
    let context = NSGraphicsContext(bitmapImageRep: bitmap)
else { fatalError("Usage: render-hearth-icon.swift output.png size") }

let s = CGFloat(size)
let ctx = context.cgContext
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
context.shouldAntialias = true
context.imageInterpolation = .high
ctx.clear(CGRect(x: 0, y: 0, width: s, height: s))

// The squircle tile every macOS icon sits on.
let tile = NSRect(x: s * 0.06, y: s * 0.06, width: s * 0.88, height: s * 0.88)
let tilePath = NSBezierPath(roundedRect: tile, xRadius: s * 0.185, yRadius: s * 0.185)
tilePath.addClip()

// Ember gradient: light at the top, deep ember at the bottom.
NSGradient(
    starting: NSColor(red: 1.00, green: 0.77, blue: 0.42, alpha: 1),
    ending: NSColor(red: 0.85, green: 0.28, blue: 0.13, alpha: 1)
)!.draw(in: tile, angle: -90)

let white = NSColor.white
let ember = NSColor(red: 0.66, green: 0.22, blue: 0.09, alpha: 1)

// Chimney, tucked into the right roof slope.
NSColor.white.setFill()
NSBezierPath(rect: NSRect(x: s * 0.635, y: s * 0.55, width: s * 0.07, height: s * 0.16)).fill()

// House body.
NSBezierPath(
    roundedRect: NSRect(x: s * 0.295, y: s * 0.175, width: s * 0.41, height: s * 0.33),
    xRadius: s * 0.035, yRadius: s * 0.035
).fill()

// Roof: a thick round-joined stroke rounds the apex and eaves.
let roof = NSBezierPath()
roof.move(to: NSPoint(x: s * 0.215, y: s * 0.415))
roof.line(to: NSPoint(x: s * 0.5, y: s * 0.715))
roof.line(to: NSPoint(x: s * 0.785, y: s * 0.415))
roof.lineWidth = s * 0.055
roof.lineJoinStyle = .round
white.setStroke()
roof.stroke()
white.setFill()
roof.fill()

// The door is a magnifying glass: search lives here. Centered in the body.
ember.setStroke()
let lens = NSBezierPath(
    ovalIn: NSRect(x: s * 0.372, y: s * 0.242, width: s * 0.226, height: s * 0.226))
lens.lineWidth = s * 0.05
lens.stroke()
let handle = NSBezierPath()
handle.move(to: NSPoint(x: s * 0.544, y: s * 0.27))
handle.line(to: NSPoint(x: s * 0.625, y: s * 0.192))
handle.lineWidth = s * 0.054
handle.lineCapStyle = .round
handle.stroke()

context.flushGraphics()
NSGraphicsContext.restoreGraphicsState()
guard let png = bitmap.representation(using: .png, properties: [:]) else {
    fatalError("Could not encode icon")
}
try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
