// De social preview voor GitHub: 1280 x 640.
//
// Draaien vanuit de hoofdmap van de repo:
//
//   swiftc -O tools/social-preview.swift -o /tmp/socialkaart && /tmp/socialkaart
//
// Uploaden kan alleen met de hand, bij Settings → General → Social preview. GitHub biedt daar
// geen API voor: `usesCustomOpenGraphImage` is in GraphQL alleen te lézen.
//
// Alles op de kaart komt uit de app zelf — de achtergrondkleur is dezelfde als
// `Palet.achtergrond`, en het paneel is een echte schermopname. Er wordt niets nagemaakt.
import AppKit

let breed: CGFloat = 1280, hoog: CGFloat = 640
let paneelPad = "docs/paneel.png"
let uit = "docs/social-preview.png"

func kleur(_ r: Int, _ g: Int, _ b: Int) -> NSColor {
    NSColor(srgbRed: CGFloat(r)/255, green: CGFloat(g)/255, blue: CGFloat(b)/255, alpha: 1)
}
// Dezelfde drie stops als Palet.achtergrond.
let verloop = NSGradient(colors: [kleur(59, 30, 110), kleur(42, 22, 82), kleur(27, 16, 56)],
                         atLocations: [0, 0.42, 1], colorSpace: .sRGB)!
let inkt = NSColor.white
let zacht = NSColor(white: 1, alpha: 0.62)
let flauw = NSColor(white: 1, alpha: 0.42)
let accent = kleur(201, 163, 255)

guard let paneel = NSImage(contentsOfFile: paneelPad) else { fatalError("geen schermafdruk") }

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(breed * 2),
    pixelsHigh: Int(hoog * 2), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
    isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
rep.size = NSSize(width: breed, height: hoog)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

// achtergrond
verloop.draw(in: NSRect(x: 0, y: 0, width: breed, height: hoog), angle: -35)

// het paneel rechts, met een zachte slagschaduw
let pH: CGFloat = 520
let pB = pH * (paneel.size.width / paneel.size.height)
let pX = breed - 64 - pB, pY = (hoog - pH) / 2
let schaduw = NSShadow()
schaduw.shadowColor = NSColor(white: 0, alpha: 0.55)
schaduw.shadowBlurRadius = 44
schaduw.shadowOffset = NSSize(width: 0, height: -14)
schaduw.set()
paneel.draw(in: NSRect(x: pX, y: pY, width: pB, height: pH))
NSShadow().set()

// de tekstkolom links
func zet(_ s: String, _ f: NSFont, _ c: NSColor, x: CGFloat, y: CGFloat, breedte: CGFloat) -> CGFloat {
    let p = NSMutableParagraphStyle(); p.lineSpacing = 4
    let a: [NSAttributedString.Key: Any] = [.font: f, .foregroundColor: c, .paragraphStyle: p]
    let hoogte = (s as NSString).boundingRect(
        with: NSSize(width: breedte, height: 400),
        options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: a).height
    (s as NSString).draw(with: NSRect(x: x, y: y - hoogte, width: breedte, height: hoogte),
                         options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: a)
    return y - hoogte
}

let x: CGFloat = 76, kolom = pX - x - 56
var y: CGFloat = hoog - 150
y = zet("Dopamine Code", NSFont.systemFont(ofSize: 60, weight: .bold), inkt,
        x: x, y: y, breedte: kolom) - 22
y = zet("Keeps your Mac awake with the lid closed.\nNo external display needed.",
        NSFont.systemFont(ofSize: 27, weight: .regular), zacht, x: x, y: y, breedte: kolom) - 34
y = zet("It puts back what that costs you:",
        NSFont.systemFont(ofSize: 19, weight: .regular), flauw, x: x, y: y, breedte: kolom) - 14
y = zet("Time limit · Battery floor · Thermal watch · Watchdog",
        NSFont.systemFont(ofSize: 20, weight: .semibold), accent, x: x, y: y, breedte: kolom) - 30
_ = zet("Free and open source · MIT", NSFont.systemFont(ofSize: 18, weight: .regular),
        flauw, x: x, y: y, breedte: kolom)

NSGraphicsContext.restoreGraphicsState()

// Terugschalen naar 1280 breed. Op 2x getekend voor scherpe tekst, maar 2560 px levert een
// PNG van 3 MB op en GitHub staat er 1 toe.
let groot = NSImage(size: NSSize(width: breed, height: hoog))
groot.addRepresentation(rep)
let klein = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(breed), pixelsHigh: Int(hoog),
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
klein.size = NSSize(width: breed, height: hoog)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: klein)
NSGraphicsContext.current?.imageInterpolation = .high
groot.draw(in: NSRect(x: 0, y: 0, width: breed, height: hoog))
NSGraphicsContext.restoreGraphicsState()

let data = klein.representation(using: .png, properties: [:])!
try! data.write(to: URL(fileURLWithPath: uit))
print("  \(uit) — \(klein.pixelsWide) x \(klein.pixelsHigh) px, \(data.count / 1024) KB")
