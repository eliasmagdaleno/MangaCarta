import AppKit
import CoreGraphics
import Foundation

// Ink & Seal app icon, drawn rather than generated.
// Paper ground + screentone + serif "M" in ink + vermilion seal.

let S: CGFloat = 1024

func hex(_ v: UInt32) -> CGColor {
    CGColor(red: CGFloat((v >> 16) & 0xFF) / 255,
            green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255, alpha: 1)
}

let paper = hex(0xF2EBDD)
let paperDeep = hex(0xE8DFCB)
let ink = hex(0x1A1714)
let seal = hex(0xE5482F)

let cs = CGColorSpaceCreateDeviceRGB()
guard let ctx = CGContext(data: nil, width: Int(S), height: Int(S), bitsPerComponent: 8,
                          bytesPerRow: 0, space: cs,
                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
    fatalError("context")
}

// Ground. No alpha anywhere: App Store icons reject transparency.
ctx.setFillColor(paper)
ctx.fill(CGRect(x: 0, y: 0, width: S, height: S))

// A soft vertical paper gradient, warm at the foot.
if let grad = CGGradient(colorsSpace: cs, colors: [paper, paperDeep] as CFArray,
                         locations: [0, 1]) {
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: S), end: CGPoint(x: 0, y: 0),
                           options: [])
}

// Screentone: the signature halftone motif, kept faint so it reads as texture.
ctx.saveGState()
ctx.setFillColor(hex(0x1A1714).copy(alpha: 0.055)!)
let pitch: CGFloat = 26
var row = 0
var y: CGFloat = 0
while y < S {
    let offset: CGFloat = row % 2 == 0 ? 0 : pitch / 2
    var x: CGFloat = offset
    while x < S {
        // Dots fade toward the top-right so the mark keeps the light.
        let t = ((x / S) + (1 - y / S)) / 2
        let r = 3.6 * (1 - 0.75 * t)
        if r > 0.5 {
            ctx.fillEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
        }
        x += pitch
    }
    y += pitch
    row += 1
}
ctx.restoreGState()

// A hairline cover plate: the framed-print motif, inset from the icon edge.
let plate = CGRect(x: S * 0.135, y: S * 0.135, width: S * 0.73, height: S * 0.73)
ctx.setStrokeColor(ink.copy(alpha: 0.9)!)
ctx.setLineWidth(7)
ctx.stroke(plate)

// The serif M, set to match `Font.inkDisplay`'s print feel.
let glyph = "M"
let fontSize: CGFloat = 520
let font = NSFont(name: "NewYork-Semibold", size: fontSize)
    ?? NSFont(name: "Didot", size: fontSize)
    ?? NSFont(descriptor: NSFont.systemFont(ofSize: fontSize).fontDescriptor
        .withDesign(.serif)!, size: fontSize)!

let attrs: [NSAttributedString.Key: Any] = [
    .font: font,
    .foregroundColor: NSColor(cgColor: ink)!
]
let line = CTLineCreateWithAttributedString(NSAttributedString(string: glyph, attributes: attrs))
let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
let gx = plate.midX - bounds.width / 2 - bounds.minX
let gy = plate.midY - bounds.height / 2 - bounds.minY + S * 0.012
ctx.textPosition = CGPoint(x: gx, y: gy)
CTLineDraw(line, ctx)

// The seal: a vermilion chop struck over the plate's lower-right corner, the way a
// print carries its maker's stamp.
let sealSize: CGFloat = 146
// Kept inside the plate: iOS masks the icon to a rounded rect, and a chop struck over
// the outer corner loses a bite of itself to that mask.
let sealRect = CGRect(x: plate.maxX - sealSize - 26, y: plate.minY + 26,
                      width: sealSize, height: sealSize)
ctx.setFillColor(seal)
ctx.addPath(CGPath(roundedRect: sealRect, cornerWidth: 22, cornerHeight: 22, transform: nil))
ctx.fillPath()

// 漫 — the first character of 漫画. Paper-coloured, knocked out of the seal.
let markSize: CGFloat = 98
let markFont = NSFont(name: "HiraginoSans-W6", size: markSize)
    ?? NSFont(name: "HiraMinProN-W6", size: markSize)
    ?? NSFont.systemFont(ofSize: markSize, weight: .semibold)
FileHandle.standardError.write("seal font: \(markFont.fontName)\n".data(using: .utf8)!)
let markAttrs: [NSAttributedString.Key: Any] = [
    .font: markFont,
    .foregroundColor: NSColor(cgColor: paper)!
]
let markLine = CTLineCreateWithAttributedString(
    NSAttributedString(string: "\u{6F2B}", attributes: markAttrs))
let markBounds = CTLineGetBoundsWithOptions(markLine, .useGlyphPathBounds)
ctx.textPosition = CGPoint(x: sealRect.midX - markBounds.width / 2 - markBounds.minX,
                           y: sealRect.midY - markBounds.height / 2 - markBounds.minY)
CTLineDraw(markLine, ctx)

guard let image = ctx.makeImage() else { fatalError("image") }
let out = URL(fileURLWithPath: CommandLine.arguments[1])
let rep = NSBitmapImageRep(cgImage: image)
guard let data = rep.representation(using: .png, properties: [:]) else { fatalError("png") }
try data.write(to: out)
print("wrote \(out.path)")

// A second file with iOS's rounded-rect mask applied, for eyeballing only.
if CommandLine.arguments.count > 2 {
    guard let maskCtx = CGContext(data: nil, width: Int(S), height: Int(S),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { fatalError("mask context") }
    let radius = S * 0.2237
    maskCtx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: S, height: S),
                           cornerWidth: radius, cornerHeight: radius, transform: nil))
    maskCtx.clip()
    maskCtx.draw(image, in: CGRect(x: 0, y: 0, width: S, height: S))
    if let masked = maskCtx.makeImage() {
        let mrep = NSBitmapImageRep(cgImage: masked)
        if let mdata = mrep.representation(using: .png, properties: [:]) {
            try mdata.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
            print("wrote masked preview")
        }
    }
}

// Usage:
//   swift scripts/make-app-icon.swift \
//     MangaCarta/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png \
//     /tmp/icon-masked.png
//
// The second path is optional and writes a preview with iOS's rounded-rect mask
// applied — the only cheap way to see whether anything near a corner gets bitten off.
//
// This is a PLACEHOLDER icon. It exists so the app is not shipping the empty-square
// default while the real icon is outsourced; it is drawn in the Ink & Seal language
// (warm paper, screentone, serif mark, one vermilion seal) so it does not look alien
// next to the app. Replace it, do not refine it.
